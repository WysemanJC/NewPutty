/*
 * dns.c: Unix implementation of dns_lookup_sshfp, using the system
 * resolver (res_nquery) so that resolv.conf settings - search
 * domains, servers, timeouts and in particular the decision whether
 * to trust the resolver's DNSSEC validation (glibc's 'trust-ad') -
 * are honoured exactly as they are for OpenSSH.
 */

#include <string.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/nameser.h>
#include <netdb.h>
#include <resolv.h>

#include "putty.h"
#include "sshfp.h"

char *dns_lookup_sshfp(const char *hostname, SshfpRecordList *out)
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
    /* Don't hang the connection for long on an unresponsive server. */
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
