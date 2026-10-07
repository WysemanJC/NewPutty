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
 * Platform-provided: look up the SSHFP records for a host name.
 * Returns NULL on success (with zero or more records), or a
 * dynamically allocated error message. "No such name" and "no SSHFP
 * records" both count as success with zero records.
 */
char *dns_lookup_sshfp(const char *hostname, SshfpRecordList *out);

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
 * Look up SSHFP records for 'hostname' and compare them against 'key'.
 * 'mode' is the CONF_ssh_verify_host_key_dns setting; if it's
 * SSHFP_OFF, nothing is looked up.
 */
void sshfp_check(const char *hostname, ssh_key *key, int mode,
                 SshfpResult *out);
void sshfp_result_clear(SshfpResult *res);

/* A short human-readable description of a result, for the Event Log. */
char *sshfp_describe(const SshfpResult *res);

#endif
