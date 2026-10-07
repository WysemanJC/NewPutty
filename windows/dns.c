/*
 * dns.c: Windows implementation of SSHFP lookups, using the system
 * resolver via DnsQuery_UTF8.
 *
 * DnsQuery gives us parsed records rather than the raw response, and
 * no trustworthy indication of DNSSEC validation, so answers are
 * always reported as not validated: SSHFP results on Windows are
 * shown to the user in the host key prompt but never skip it.
 *
 * DnsQuery blocks, so each lookup runs on its own short-lived thread,
 * which does nothing but the query itself and then signals an event
 * that the main loop is waiting on. Only the main thread ever calls
 * back into PuTTY or frees a query.
 */

#include "putty.h"
#include "sshfp.h"

#include <windns.h>

DECL_WINDOWS_FUNCTION(static, DNS_STATUS, DnsQuery_UTF8,
                      (PCSTR, WORD, DWORD, PIP4_ARRAY, PDNS_RECORDA *,
                       PVOID *));
DECL_WINDOWS_FUNCTION(static, VOID, DnsFree, (PVOID, DNS_FREE_TYPE));

static bool dnsapi_loaded(void)
{
    static bool tried = false;
    static HMODULE dnsapi;
    if (!tried) {
        tried = true;
        dnsapi = load_system32_dll("dnsapi.dll");
        GET_WINDOWS_FUNCTION(dnsapi, DnsQuery_UTF8);
        GET_WINDOWS_FUNCTION(dnsapi, DnsFree);
    }
    return p_DnsQuery_UTF8 && p_DnsFree;
}

struct SshfpQuery {
    char *fqdn;
    sshfp_query_done_fn done;
    void *ctx;
    bool cancelled;                    /* main thread only */
    HANDLE event;                      /* set by the thread when finished */
    HandleWait *wait;

    /*
     * Written by the lookup thread, and read by the main thread only
     * after the thread has set 'event'.
     */
    DNS_STATUS status;
    SshfpRecordList recs;

    char *err;                         /* main thread only */
};

/*
 * Runs on the lookup thread, so it must not touch anything shared
 * with the main thread: it only calls DnsQuery and allocates memory.
 * (In particular, error messages are formatted on the main thread,
 * because win_strerror keeps a cache.)
 */
static DWORD WINAPI lookup_thread(void *vq)
{
    SshfpQuery *q = (SshfpQuery *)vq;

    PDNS_RECORDA results = NULL;
    q->status = p_DnsQuery_UTF8(
        q->fqdn, DNS_TYPE_SSHFP_VALUE,
        DNS_QUERY_STANDARD | DNS_QUERY_NO_HOSTS_FILE,
        NULL, &results, NULL);

    if (q->status == 0) {
        for (PDNS_RECORDA rec = results; rec; rec = rec->pNext) {
            if (rec->wType != DNS_TYPE_SSHFP_VALUE ||
                rec->Flags.S.Section != DnsSectionAnswer)
                continue;
            /*
             * Record types Windows doesn't know come back as raw
             * RDATA starting at Data itself, with its length in
             * wDataLength. (DNS_UNKNOWN_DATA's dwByteCount is not
             * filled in: reading it takes the first RDATA bytes as a
             * length.)
             */
            DWORD len = rec->wDataLength;
            const BYTE *data = (const BYTE *)&rec->Data;
            if (len < 3)
                continue;
            sgrowarray(q->recs.recs, q->recs.size, q->recs.n);
            SshfpRecord *r = &q->recs.recs[q->recs.n++];
            r->alg = data[0];
            r->fptype = data[1];
            r->fp = strbuf_new();
            put_data(r->fp, data + 2, len - 2);
        }
    }
    if (results)
        p_DnsFree(results, DnsFreeRecordList);

    /* After this, the query belongs to the main thread again. */
    SetEvent(q->event);
    return 0;
}

static void query_free(SshfpQuery *q)
{
    if (q->wait)
        delete_handle_wait(q->wait);
    if (q->event)
        CloseHandle(q->event);
    sfree(q->fqdn);
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

static void lookup_finished(void *vq)
{
    SshfpQuery *q = (SshfpQuery *)vq;

    if (q->status == DNS_ERROR_RCODE_NAME_ERROR ||
        q->status == DNS_INFO_NO_RECORDS) {
        /* simply no records */
    } else if (q->status != 0) {
        q->err = dupprintf("lookup of %s failed: %s", q->fqdn,
                           win_strerror(q->status));
    }
    query_finish(q);
}

static void query_failed_to_start(void *vq)
{
    query_finish((SshfpQuery *)vq);
}

SshfpQuery *dns_lookup_sshfp_start(const char *hostname,
                                   sshfp_query_done_fn done, void *ctx)
{
    SshfpQuery *q = snew(SshfpQuery);
    memset(q, 0, sizeof(*q));
    /*
     * Use the name exactly as given (plus a trailing dot), rather
     * than letting the DNS suffix search list apply, as on Unix.
     */
    q->fqdn = (hostname[strlen(hostname) - 1] == '.') ?
        dupstr(hostname) : dupcat(hostname, ".");
    q->done = done;
    q->ctx = ctx;

    /* Load the DLL here, so that the thread only reads the pointers. */
    if (!dnsapi_loaded()) {
        q->err = dupstr("DNS API (dnsapi.dll) is not available");
        queue_toplevel_callback(query_failed_to_start, q);
        return q;
    }

    q->event = CreateEvent(NULL, TRUE, FALSE, NULL);
    HANDLE thread = NULL;
    if (q->event) {
        DWORD tid;
        thread = CreateThread(NULL, 0, lookup_thread, q, 0, &tid);
    }
    if (!thread) {
        q->err = dupprintf("unable to start DNS lookup: %s",
                           win_strerror(GetLastError()));
        queue_toplevel_callback(query_failed_to_start, q);
        return q;
    }
    CloseHandle(thread);
    q->wait = add_handle_wait(q->event, lookup_finished, q);
    return q;
}

void dns_lookup_sshfp_cancel(SshfpQuery *q)
{
    /*
     * The lookup thread may still be using the query, so don't free
     * it here: just make sure nobody is told the result. It's freed
     * when the thread signals completion (or by the pending callback,
     * if the thread never started).
     */
    q->cancelled = true;
}
