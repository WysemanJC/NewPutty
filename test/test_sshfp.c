/*
 * test_sshfp.c: tests for the SSHFP DNS response parser and key
 * matching in ssh/sshfp.c, including random-input robustness.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "putty.h"
#include "ssh.h"
#include "sshfp.h"

static int fails, passes;

#define CHECK(cond) do {                                        \
        if (cond) {                                             \
            passes++;                                           \
        } else {                                                \
            fails++;                                            \
            fprintf(stderr, "%s:%d: check failed: %s\n",        \
                    __FILE__, __LINE__, #cond);                 \
        }                                                       \
    } while (0)

void modalfatalbox(const char *p, ...)
{
    fprintf(stderr, "FATAL ERROR: %s\n", p);
    exit(1);
}

void random_read(void *buf, size_t size)
{
    modalfatalbox("random_read called in test_sshfp");
}

/*
 * The test supplies the "DNS" answer that the SSHFP check sees, and
 * plays the event loop: a lookup started by sshfp_check_start stays
 * pending until fake_complete() answers it.
 */
static SshfpRecordList fake_answer;
static const char *fake_error;

struct SshfpQuery {
    sshfp_query_done_fn done;
    void *ctx;
    bool cancelled;
};
static SshfpQuery *fake_pending;

SshfpQuery *dns_lookup_sshfp_start(const char *hostname,
                                   sshfp_query_done_fn done, void *ctx)
{
    SshfpQuery *q = snew(SshfpQuery);
    q->done = done;
    q->ctx = ctx;
    q->cancelled = false;
    CHECK(!fake_pending);
    fake_pending = q;
    return q;
}

void dns_lookup_sshfp_cancel(SshfpQuery *q)
{
    q->cancelled = true;
}

static void fake_complete(void)
{
    SshfpQuery *q = fake_pending;
    fake_pending = NULL;
    if (!q)
        return;

    SshfpRecordList recs = { 0 };
    recs.secure = fake_answer.secure;
    for (size_t i = 0; i < fake_answer.n; i++) {
        sgrowarray(recs.recs, recs.size, recs.n);
        recs.recs[recs.n].alg = fake_answer.recs[i].alg;
        recs.recs[recs.n].fptype = fake_answer.recs[i].fptype;
        recs.recs[recs.n].fp = strbuf_dup(
            ptrlen_from_strbuf(fake_answer.recs[i].fp));
        recs.n++;
    }
    if (!q->cancelled)
        q->done(q->ctx, fake_error, &recs);
    sshfp_record_list_free(&recs);
    sfree(q);
}

/* Collects the result of one check. */
typedef struct CheckOutcome {
    bool called;
    SshfpStatus status;
    bool secure;
    char *desc;
} CheckOutcome;

static void check_done(void *vctx, const SshfpResult *res)
{
    CheckOutcome *out = (CheckOutcome *)vctx;
    CHECK(!out->called);
    out->called = true;
    out->status = res->status;
    out->secure = res->secure;
    out->desc = sshfp_describe(res);
}

/* Run a whole check, as the event loop would; NOT_CHECKED if no lookup. */
static SshfpStatus run_check(const char *host, ssh_key *key, int mode,
                             CheckOutcome *out)
{
    memset(out, 0, sizeof(*out));
    SshfpCheck *chk = sshfp_check_start(host, key, mode, check_done, out);
    if (!chk) {
        CHECK(!fake_pending);
        return SSHFP_NOT_CHECKED;
    }
    CHECK(!out->called);       /* never called back from inside start */
    fake_complete();
    CHECK(out->called);
    return out->status;
}

static void outcome_free(CheckOutcome *out)
{
    sfree(out->desc);
    out->desc = NULL;
}

static void put_name(strbuf *sb, const char *name)
{
    while (*name) {
        size_t len = strcspn(name, ".");
        put_byte(sb, len);
        put_data(sb, name, len);
        name += len;
        if (*name == '.')
            name++;
    }
    put_byte(sb, 0);
}

static strbuf *make_response(unsigned flags, bool with_cname)
{
    strbuf *sb = strbuf_new();
    put_uint16(sb, 0x1234);
    put_uint16(sb, flags);
    put_uint16(sb, 1);
    put_uint16(sb, with_cname ? 3 : 2);
    put_uint16(sb, 0);
    put_uint16(sb, 0);
    put_name(sb, "host.example");
    put_uint16(sb, 44);
    put_uint16(sb, 1);
    if (with_cname) {
        put_uint16(sb, 0xC00C);
        put_uint16(sb, 5);             /* CNAME */
        put_uint16(sb, 1);
        put_uint32(sb, 60);
        put_uint16(sb, 7);
        put_name(sb, "x.ex");          /* 6 bytes... */
        put_byte(sb, 0);               /* ...padded to rdlength 7 */
    }
    for (int i = 0; i < 2; i++) {
        put_uint16(sb, 0xC00C);
        put_uint16(sb, 44);
        put_uint16(sb, 1);
        put_uint32(sb, 60);
        put_uint16(sb, 2 + 32);
        put_byte(sb, 4);
        put_byte(sb, 2);
        for (int j = 0; j < 32; j++)
            put_byte(sb, i * 32 + j);
    }
    return sb;
}

static void test_parse(void)
{
    SshfpRecordList list = { 0 };
    strbuf *msg = make_response(0x81A0, true);   /* QR RD RA AD */
    char *err = sshfp_parse_dns_response(ptrlen_from_strbuf(msg), &list);
    CHECK(!err);
    CHECK(list.n == 2);
    CHECK(list.secure);
    if (list.n == 2) {
        CHECK(list.recs[1].alg == 4 && list.recs[1].fptype == 2);
        CHECK(list.recs[1].fp->len == 32 && list.recs[1].fp->u[0] == 32);
    }
    sshfp_record_list_free(&list);
    sfree(err);

    /* Every truncation must fail cleanly or parse a prefix. */
    for (size_t len = 0; len < msg->len; len++) {
        list.secure = false;
        err = sshfp_parse_dns_response(make_ptrlen(msg->u, len), &list);
        CHECK(err != NULL || list.n <= 2);
        sshfp_record_list_free(&list);
        sfree(err);
    }
    strbuf_free(msg);

    /* No AD bit. */
    msg = make_response(0x8180, false);
    err = sshfp_parse_dns_response(ptrlen_from_strbuf(msg), &list);
    CHECK(!err && list.n == 2 && !list.secure);
    sshfp_record_list_free(&list);
    strbuf_free(msg);

    /* Truncated (TC) and SERVFAIL responses are errors; NXDOMAIN isn't. */
    msg = make_response(0x8380, false);
    err = sshfp_parse_dns_response(ptrlen_from_strbuf(msg), &list);
    CHECK(err != NULL);
    sfree(err);
    strbuf_free(msg);
    msg = make_response(0x8182, false);
    err = sshfp_parse_dns_response(ptrlen_from_strbuf(msg), &list);
    CHECK(err != NULL);
    sfree(err);
    strbuf_free(msg);
    msg = make_response(0x8183, false);
    err = sshfp_parse_dns_response(ptrlen_from_strbuf(msg), &list);
    CHECK(!err && list.n == 0);
    strbuf_free(msg);

    /* Random garbage must never crash (run under ASan to be sure). */
    srand(1);
    for (int i = 0; i < 20000; i++) {
        unsigned char buf[300];
        size_t len = rand() % sizeof(buf);
        for (size_t j = 0; j < len; j++)
            buf[j] = rand();
        if (len > 3)
            buf[2] |= 0x80;            /* make most of them responses */
        err = sshfp_parse_dns_response(make_ptrlen(buf, len), &list);
        sshfp_record_list_free(&list);
        sfree(err);
    }
}

static void fake_add(unsigned alg, unsigned fptype, ptrlen fp)
{
    sgrowarray(fake_answer.recs, fake_answer.size, fake_answer.n);
    SshfpRecord *r = &fake_answer.recs[fake_answer.n++];
    r->alg = alg;
    r->fptype = fptype;
    r->fp = strbuf_dup(fp);
}

static void test_match(void)
{
    /* An arbitrary valid Ed25519 public key. */
    static const unsigned char pub[32] = {
        0x05, 0xe1, 0x82, 0xe0, 0xe7, 0x7b, 0xe5, 0x79, 0x4b, 0x0b, 0x62,
        0x45, 0x50, 0x1e, 0x9b, 0x77, 0xbe, 0x0b, 0xf7, 0xef, 0x4d, 0xfd,
        0x13, 0x28, 0x4b, 0xa7, 0xbe, 0x26, 0x0a, 0x60, 0xb8, 0xa9,
    };
    strbuf *blob = strbuf_new();
    put_stringz(blob, "ssh-ed25519");
    put_string(blob, pub, 32);
    ssh_key *key = ssh_key_new_pub(&ssh_ecdsa_ed25519, ptrlen_from_strbuf(blob));
    CHECK(key);
    if (!key) {
        strbuf_free(blob);
        return;
    }

    unsigned char sha256[32], sha1[20];
    hash_simple(&ssh_sha256, ptrlen_from_strbuf(blob), sha256);
    hash_simple(&ssh_sha1, ptrlen_from_strbuf(blob), sha1);

    CheckOutcome res;

    CHECK(run_check("host.example", key, SSHFP_OFF, &res) ==
          SSHFP_NOT_CHECKED);
    CHECK(run_check("192.0.2.1", key, SSHFP_YES, &res) ==
          SSHFP_NOT_CHECKED);
    CHECK(run_check("2001:db8::1", key, SSHFP_YES, &res) ==
          SSHFP_NOT_CHECKED);

    CHECK(run_check("host.example", key, SSHFP_YES, &res) ==
          SSHFP_NO_RECORDS);
    outcome_free(&res);

    fake_add(1, 2, make_ptrlen(sha256, 32));     /* right hash, wrong alg */
    CHECK(run_check("host.example", key, SSHFP_YES, &res) ==
          SSHFP_NO_RECORDS);
    outcome_free(&res);

    unsigned char wrong[32];
    memcpy(wrong, sha256, 32);
    wrong[31] ^= 1;
    fake_add(4, 2, make_ptrlen(wrong, 32));
    CHECK(run_check("host.example", key, SSHFP_YES, &res) ==
          SSHFP_MISMATCH);
    outcome_free(&res);

    fake_add(4, 1, make_ptrlen(sha1, 20));
    fake_answer.secure = true;
    CHECK(run_check("host.example", key, SSHFP_ASK, &res) == SSHFP_MATCH);
    CHECK(res.secure);
    outcome_free(&res);

    fake_error = "simulated failure";
    CHECK(run_check("host.example", key, SSHFP_YES, &res) ==
          SSHFP_LOOKUP_FAILED);
    CHECK(res.desc && strstr(res.desc, "simulated failure") != NULL);
    outcome_free(&res);
    fake_error = NULL;

    /* A cancelled check never calls back, and frees everything. */
    memset(&res, 0, sizeof(res));
    SshfpCheck *chk = sshfp_check_start("host.example", key, SSHFP_ASK,
                                        check_done, &res);
    CHECK(chk && fake_pending);
    sshfp_check_cancel(chk);
    fake_complete();
    CHECK(!res.called);

    /* The key needn't outlive sshfp_check_start. */
    ssh_key *key2 = ssh_key_new_pub(&ssh_ecdsa_ed25519,
                                    ptrlen_from_strbuf(blob));
    memset(&res, 0, sizeof(res));
    chk = sshfp_check_start("host.example", key2, SSHFP_ASK,
                            check_done, &res);
    ssh_key_free(key2);
    CHECK(chk != NULL);
    fake_complete();
    CHECK(res.called && res.status == SSHFP_MATCH);
    outcome_free(&res);

    sshfp_record_list_free(&fake_answer);
    ssh_key_free(key);
    strbuf_free(blob);
}

int main(void)
{
    test_parse();
    test_match();
    printf("%d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
