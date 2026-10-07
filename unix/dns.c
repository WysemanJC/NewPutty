/*
 * dns.c: Unix implementation of SSHFP lookups, using the system
 * resolver (res_nquery) so that resolv.conf settings - search
 * domains, servers, timeouts and in particular the decision whether
 * to trust the resolver's DNSSEC validation (glibc's 'trust-ad') -
 * are honoured exactly as they are for OpenSSH.
 *
 * res_nquery blocks, so each lookup runs on its own short-lived
 * thread, which does nothing but the query itself. The finished query
 * is handed back to the main thread through a pipe watched by the
 * event loop; only the main thread ever calls back into PuTTY or
 * frees a query.
 */

#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/nameser.h>
#include <netdb.h>
#include <resolv.h>

#include "putty.h"
#include "sshfp.h"

/*
 * Runs on the lookup thread, so it must not touch anything shared
 * with the main thread: it only allocates memory and calls the
 * resolver.
 */
static char *lookup_blocking(const char *hostname, SshfpRecordList *out)
{
    struct __res_state rs;
    memset(&rs, 0, sizeof(rs));
    if (res_ninit(&rs) != 0)
        return dupstr("unable to initialise the DNS resolver");

    /* Ask for DNSSEC data so that a validating resolver sets AD. */
#ifdef RES_USE_EDNS0
    rs.options |= RES_USE_EDNS0;
#endif
#ifdef RES_USE_DNSSEC
    rs.options |= RES_USE_DNSSEC;
#endif
    /* Don't keep the user waiting long on an unresponsive server. */
    if (rs.retrans > 2)
        rs.retrans = 2;
    if (rs.retry > 2)
        rs.retry = 2;

    /*
     * Use the name exactly as given (plus a trailing dot), rather
     * than letting search domains apply, which could otherwise make
     * a short name pick up some other domain's records.
     */
    char *fqdn = (hostname[strlen(hostname) - 1] == '.') ?
        dupstr(hostname) : dupcat(hostname, ".");

    size_t bufsize = 65536;
    unsigned char *buf = snewn(bufsize, unsigned char);
    int len = res_nquery(&rs, fqdn, ns_c_in, DNS_TYPE_SSHFP_VALUE,
                         buf, bufsize);
    char *err = NULL;

    if (len < 0) {
        int herr = rs.res_h_errno;
        if (herr != HOST_NOT_FOUND && herr != NO_DATA)
            err = dupprintf("lookup of %s failed: %s", fqdn,
                            hstrerror(herr));
        /* Otherwise there are simply no records. */
    } else {
        err = sshfp_parse_dns_response(make_ptrlen(buf, len), out);
    }

    sfree(buf);
    sfree(fqdn);
    res_nclose(&rs);
    return err;
}

struct SshfpQuery {
    char *hostname;
    sshfp_query_done_fn done;
    void *ctx;
    bool cancelled;                    /* main thread only */

    /*
     * Written by the lookup thread, and read by the main thread only
     * after the thread has passed the query back through the pipe.
     */
    SshfpRecordList recs;
    char *err;
};

/* Shared by all queries in the process; created on first use. */
static int done_pipe[2] = { -1, -1 };

static void query_free(SshfpQuery *q)
{
    sfree(q->hostname);
    sfree(q->err);
    sshfp_record_list_free(&q->recs);
    sfree(q);
}

static void query_finish(SshfpQuery *q)
{
    if (!q->cancelled)
        q->done(q->ctx, q->err, &q->recs);
    query_free(q);
}

static void done_pipe_readable(int fd, int event)
{
    SshfpQuery *q;
    while (true) {
        ssize_t got = read(fd, &q, sizeof(q));
        if (got != sizeof(q))
            break;      /* EAGAIN once drained; a pointer is never split */
        query_finish(q);
    }
}

static void query_failed_to_start(void *vq)
{
    query_finish((SshfpQuery *)vq);
}

static void *lookup_thread(void *vq)
{
    SshfpQuery *q = (SshfpQuery *)vq;
    q->err = lookup_blocking(q->hostname, &q->recs);

    /*
     * Hand the query back. A pointer is much smaller than PIPE_BUF,
     * so the write is atomic. After this, the query belongs to the
     * main thread again and we must not touch it.
     */
    ssize_t ret;
    do {
        ret = write(done_pipe[1], &q, sizeof(q));
    } while (ret < 0 && errno == EINTR);
    return NULL;
}

static bool start_thread(SshfpQuery *q)
{
    if (done_pipe[0] < 0) {
        int fds[2];
        if (pipe(fds) < 0)
            return false;
        for (int i = 0; i < 2; i++)
            fcntl(fds[i], F_SETFD, FD_CLOEXEC);
        fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK);
        done_pipe[0] = fds[0];
        done_pipe[1] = fds[1];
        uxsel_set(done_pipe[0], SELECT_R, done_pipe_readable);
    }

    pthread_attr_t attr;
    pthread_t thread;
    if (pthread_attr_init(&attr) != 0)
        return false;
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    bool ok = (pthread_create(&thread, &attr, lookup_thread, q) == 0);
    pthread_attr_destroy(&attr);
    return ok;
}

SshfpQuery *dns_lookup_sshfp_start(const char *hostname,
                                   sshfp_query_done_fn done, void *ctx)
{
    SshfpQuery *q = snew(SshfpQuery);
    memset(q, 0, sizeof(*q));
    q->hostname = dupstr(hostname);
    q->done = done;
    q->ctx = ctx;

    if (!start_thread(q)) {
        q->err = dupstr("unable to start a DNS lookup thread");
        queue_toplevel_callback(query_failed_to_start, q);
    }
    return q;
}

void dns_lookup_sshfp_cancel(SshfpQuery *q)
{
    /*
     * The lookup thread may still be using the query, so don't free
     * it here: just make sure nobody is told the result. It's freed
     * when the thread hands it back (or by the pending callback, if
     * the thread never started).
     */
    q->cancelled = true;
}
