/*
 * dns.c: Windows implementation of dns_lookup_sshfp, using the
 * system resolver via DnsQuery_UTF8.
 *
 * DnsQuery gives us parsed records rather than the raw response, and
 * no trustworthy indication of DNSSEC validation, so answers are
 * always reported as not validated: SSHFP results on Windows are
 * shown to the user in the host key prompt but never skip it.
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

char *dns_lookup_sshfp(const char *hostname, SshfpRecordList *out)
{
    if (!dnsapi_loaded())
        return dupstr("DNS API (dnsapi.dll) is not available");

    out->secure = false;

    PDNS_RECORDA results = NULL;
    DNS_STATUS status = p_DnsQuery_UTF8(
        hostname, DNS_TYPE_SSHFP_VALUE,
        DNS_QUERY_STANDARD | DNS_QUERY_NO_HOSTS_FILE,
        NULL, &results, NULL);

    if (status == DNS_ERROR_RCODE_NAME_ERROR ||
        status == DNS_INFO_NO_RECORDS)
        return NULL;                   /* simply no records */
    if (status != 0)
        return dupprintf("lookup of %s failed: %s", hostname,
                         win_strerror(status));

    for (PDNS_RECORDA rec = results; rec; rec = rec->pNext) {
        if (rec->wType != DNS_TYPE_SSHFP_VALUE ||
            rec->Flags.S.Section != DnsSectionAnswer)
            continue;
        /*
         * Record types Windows doesn't know come back as raw RDATA
         * starting at Data itself, with its length in wDataLength.
         * (DNS_UNKNOWN_DATA's dwByteCount is not filled in: reading
         * it takes the first RDATA bytes as a length.)
         */
        DWORD len = rec->wDataLength;
        const BYTE *data = (const BYTE *)&rec->Data;
        if (len < 3)
            continue;
        sgrowarray(out->recs, out->size, out->n);
        SshfpRecord *r = &out->recs[out->n++];
        r->alg = data[0];
        r->fptype = data[1];
        r->fp = strbuf_new();
        put_data(r->fp, data + 2, len - 2);
    }

    p_DnsFree(results, DnsFreeRecordList);
    return NULL;
}
