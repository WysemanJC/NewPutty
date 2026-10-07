/*
 * sshfp.c: platform-independent parts of SSHFP host key checking.
 * See sshfp.h.
 */

#include <assert.h>
#include <string.h>

#include "putty.h"
#include "ssh.h"
#include "sshfp.h"

void sshfp_record_list_free(SshfpRecordList *list)
{
    for (size_t i = 0; i < list->n; i++)
        strbuf_free(list->recs[i].fp);
    sfree(list->recs);
    list->recs = NULL;
    list->n = list->size = 0;
}

static void add_record(SshfpRecordList *list, unsigned alg, unsigned fptype,
                       ptrlen fp)
{
    sgrowarray(list->recs, list->size, list->n);
    SshfpRecord *rec = &list->recs[list->n++];
    rec->alg = alg;
    rec->fptype = fptype;
    rec->fp = strbuf_new();
    put_datapl(rec->fp, fp);
}

/* ----------------------------------------------------------------------
 * Minimal DNS message parsing: just enough to pull SSHFP RRs out of
 * the answer section. (RFC 1035 section 4.)
 */

#define DNS_CLASS_IN 1

/* Skip a possibly-compressed domain name. */
static bool skip_name(BinarySource *src)
{
    for (int labels = 0; labels < 128; labels++) {
        unsigned len = get_byte(src);
        if (get_err(src))
            return false;
        if (len == 0)
            return true;
        if ((len & 0xC0) == 0xC0) {
            get_byte(src);             /* second byte of the pointer */
            return !get_err(src);
        }
        if (len & 0xC0)
            return false;              /* reserved label types */
        get_data(src, len);
        if (get_err(src))
            return false;
    }
    return false;
}

char *sshfp_parse_dns_response(ptrlen msg, SshfpRecordList *out)
{
    BinarySource src[1];
    BinarySource_BARE_INIT_PL(src, msg);

    get_uint16(src);                   /* ID */
    unsigned flags = get_uint16(src);
    unsigned qdcount = get_uint16(src);
    unsigned ancount = get_uint16(src);
    get_uint16(src);                   /* NSCOUNT */
    get_uint16(src);                   /* ARCOUNT */
    if (get_err(src))
        return dupstr("DNS response too short");

    if (!(flags & 0x8000))
        return dupstr("DNS message is not a response");
    if (flags & 0x0200)
        return dupstr("DNS response was truncated");
    unsigned rcode = flags & 0x000F;
    if (rcode == 3)                    /* NXDOMAIN: no records */
        return NULL;
    if (rcode != 0)
        return dupprintf("DNS server returned error code %u", rcode);

    out->secure = (flags & 0x0020) != 0;   /* AD bit */

    for (unsigned i = 0; i < qdcount; i++) {
        if (!skip_name(src))
            return dupstr("malformed question in DNS response");
        get_uint16(src);               /* QTYPE */
        get_uint16(src);               /* QCLASS */
    }

    for (unsigned i = 0; i < ancount; i++) {
        if (!skip_name(src))
            return dupstr("malformed answer in DNS response");
        unsigned type = get_uint16(src);
        unsigned class = get_uint16(src);
        get_uint32(src);               /* TTL */
        unsigned rdlength = get_uint16(src);
        ptrlen rdata = get_data(src, rdlength);
        if (get_err(src))
            return dupstr("malformed answer in DNS response");

        if (type != DNS_TYPE_SSHFP_VALUE || class != DNS_CLASS_IN)
            continue;                  /* e.g. a CNAME in the chain */

        BinarySource rd[1];
        BinarySource_BARE_INIT_PL(rd, rdata);
        unsigned alg = get_byte(rd);
        unsigned fptype = get_byte(rd);
        ptrlen fp = get_data(rd, get_avail(rd));
        if (get_err(rd) || fp.len == 0)
            continue;                  /* ignore a malformed record */
        add_record(out, alg, fptype, fp);
    }

    return NULL;
}

/* ----------------------------------------------------------------------
 * Matching a key against the records.
 */

/* SSHFP algorithm number for a public key blob, or 0 if none. */
static unsigned sshfp_alg_for_blob(ptrlen blob)
{
    BinarySource src[1];
    BinarySource_BARE_INIT_PL(src, blob);
    ptrlen type = get_string(src);
    if (get_err(src))
        return 0;

    if (ptrlen_eq_string(type, "ssh-rsa"))
        return 1;
    if (ptrlen_eq_string(type, "ssh-dss"))
        return 2;
    if (ptrlen_startswith(type, PTRLEN_LITERAL("ecdsa-sha2-"), NULL))
        return 3;
    if (ptrlen_eq_string(type, "ssh-ed25519"))
        return 4;
    if (ptrlen_eq_string(type, "ssh-ed448"))
        return 6;
    return 0;
}

/*
 * Literal IP addresses can't usefully have SSHFP records, so don't
 * leak a pointless query to the resolver.
 */
static bool hostname_is_ip_literal(const char *host)
{
    if (strchr(host, ':'))
        return true;                   /* IPv6 */
    for (const char *p = host; *p; p++)
        if (!(*p == '.' || (*p >= '0' && *p <= '9')))
            return false;
    return true;
}

static SshfpStatus match_records(const SshfpRecordList *list, ptrlen blob)
{
    unsigned alg = sshfp_alg_for_blob(blob);
    unsigned char sha1[20], sha256[32];
    hash_simple(&ssh_sha1, blob, sha1);
    hash_simple(&ssh_sha256, blob, sha256);

    bool any = false;
    for (size_t i = 0; i < list->n; i++) {
        const SshfpRecord *rec = &list->recs[i];
        if (rec->alg != alg)
            continue;

        const unsigned char *want;
        size_t wantlen;
        if (rec->fptype == 1) {
            want = sha1;
            wantlen = sizeof(sha1);
        } else if (rec->fptype == 2) {
            want = sha256;
            wantlen = sizeof(sha256);
        } else {
            continue;                  /* unknown fingerprint type */
        }

        any = true;
        if (rec->fp->len == wantlen && smemeq(rec->fp->u, want, wantlen))
            return SSHFP_MATCH;
    }
    return any ? SSHFP_MISMATCH : SSHFP_NO_RECORDS;
}

void sshfp_check(const char *hostname, ssh_key *key, int mode,
                 SshfpResult *out)
{
    out->status = SSHFP_NOT_CHECKED;
    out->secure = false;
    out->error = NULL;

    if (mode == SSHFP_OFF || !key || !hostname || !*hostname ||
        ssh_key_alg(key)->is_certificate || hostname_is_ip_literal(hostname))
        return;

    strbuf *blob = strbuf_new();
    ssh_key_public_blob(key, BinarySink_UPCAST(blob));
    if (!sshfp_alg_for_blob(ptrlen_from_strbuf(blob))) {
        strbuf_free(blob);
        return;                        /* no SSHFP algorithm number */
    }

    SshfpRecordList list = { 0 };
    char *err = dns_lookup_sshfp(hostname, &list);
    if (err) {
        out->status = SSHFP_LOOKUP_FAILED;
        out->error = err;
    } else {
        out->status = match_records(&list, ptrlen_from_strbuf(blob));
        out->secure = list.secure;
    }

    sshfp_record_list_free(&list);
    strbuf_free(blob);
}

void sshfp_result_clear(SshfpResult *res)
{
    sfree(res->error);
    res->error = NULL;
    res->status = SSHFP_NOT_CHECKED;
}

char *sshfp_describe(const SshfpResult *res)
{
    const char *sec = res->secure ?
        "DNSSEC-validated" : "not DNSSEC-validated";
    switch (res->status) {
      case SSHFP_NOT_CHECKED:
        return dupstr("SSHFP: not checked");
      case SSHFP_LOOKUP_FAILED:
        return dupprintf("SSHFP: DNS lookup failed: %s", res->error);
      case SSHFP_NO_RECORDS:
        return dupstr("SSHFP: no matching-algorithm records in DNS");
      case SSHFP_MISMATCH:
        return dupprintf("SSHFP: DNS records do NOT match the host key (%s)",
                         sec);
      case SSHFP_MATCH:
        return dupprintf("SSHFP: host key matches DNS record (%s)", sec);
    }
    unreachable("bad SshfpStatus");
}
