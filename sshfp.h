/*
 * sshfp.h: checking SSH host keys against SSHFP records in the DNS
 * (RFC 4255, with SHA-256 fingerprints from RFC 6594 and Ed25519 /
 * Ed448 from RFC 7479 / RFC 8709).
 */

#ifndef PUTTY_SSHFP_H
#define PUTTY_SSHFP_H

#include "defs.h"

#define DNS_TYPE_SSHFP_VALUE 44

/* One SSHFP resource record. */
typedef struct SshfpRecord {
    unsigned alg;       /* 1 RSA, 2 DSA, 3 ECDSA, 4 Ed25519, 6 Ed448 */
    unsigned fptype;    /* 1 SHA-1, 2 SHA-256 */
    strbuf *fp;         /* raw fingerprint bytes */
} SshfpRecord;

typedef struct SshfpRecordList {
    SshfpRecord *recs;
    size_t n, size;
    /*
     * True if the resolver said the answer was DNSSEC-validated (the
     * AD bit). This is only trustworthy if the resolver itself is
     * trusted, which is the system's decision (e.g. glibc's trust-ad
     * option); we never set the AD bit to true ourselves.
     */
    bool secure;
} SshfpRecordList;

void sshfp_record_list_free(SshfpRecordList *list);

/*
 * Parse a raw DNS response message (as returned by res_query) and
 * collect any SSHFP records in its answer section. Returns NULL on
 * success, or a dynamically allocated error message.
 */
char *sshfp_parse_dns_response(ptrlen msg, SshfpRecordList *out);

/*
 * Platform-provided: look up the SSHFP records for a host name,
 * without blocking. A DNS lookup can take seconds, and almost
 * nothing in PuTTY may block, so the platform runs the query in the
 * background and reports back through the event loop.
 *
 * 'done' is called exactly once, from the event loop (never from
 * within dns_lookup_sshfp_start itself), unless the query is
 * cancelled first. 'err' is NULL on success, with zero or more
 * records in 'recs'; otherwise it is an error message. Both belong to
 * the query and are freed once 'done' returns. "No such name" and "no
 * SSHFP records" both count as success with zero records.
 *
 * After dns_lookup_sshfp_cancel, 'done' is never called; any lookup
 * still in progress is abandoned and cleaned up when it finishes.
 */
typedef struct SshfpQuery SshfpQuery;
typedef void (*sshfp_query_done_fn)(void *ctx, const char *err,
                                    const SshfpRecordList *recs);
SshfpQuery *dns_lookup_sshfp_start(const char *hostname,
                                   sshfp_query_done_fn done, void *ctx);
void dns_lookup_sshfp_cancel(SshfpQuery *q);

typedef enum SshfpStatus {
    SSHFP_NOT_CHECKED,  /* disabled, unsuitable key, or IP literal */
    SSHFP_LOOKUP_FAILED,
    SSHFP_NO_RECORDS,   /* no SSHFP records for this key's algorithm */
    SSHFP_MISMATCH,     /* records exist, but none match this key */
    SSHFP_MATCH,        /* a record matches this key */
} SshfpStatus;

typedef struct SshfpResult {
    SshfpStatus status;
    bool secure;        /* the DNS answer was DNSSEC-validated */
    char *error;        /* for SSHFP_LOOKUP_FAILED */
} SshfpResult;

/*
 * Start looking up SSHFP records for 'hostname', to compare them
 * against 'key'. 'mode' is the CONF_ssh_verify_host_key_dns setting.
 *
 * Returns NULL if there is nothing to look up (SSHFP_OFF, no key, a
 * certificate, a key type SSHFP can't describe, or an IP literal);
 * 'done' is then never called. Otherwise 'done' is called later from
 * the event loop with the result, which belongs to the check and is
 * freed once 'done' returns, unless sshfp_check_cancel is called
 * first. 'key' need not outlive this call.
 */
typedef struct SshfpCheck SshfpCheck;
typedef void (*sshfp_check_done_fn)(void *ctx, const SshfpResult *res);
SshfpCheck *sshfp_check_start(const char *hostname, ssh_key *key, int mode,
                              sshfp_check_done_fn done, void *ctx);
void sshfp_check_cancel(SshfpCheck *chk);

/* A short human-readable description of a result, for the Event Log. */
char *sshfp_describe(const SshfpResult *res);

#endif
