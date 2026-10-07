/*
 * test_jsonstore.c: tests for the JSON parser/writer and the JSON
 * implementation of storage.h.
 *
 * Usage: test_jsonstore <empty scratch directory>
 * The directory is used as $PUTTYDIR.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "putty.h"
#include "storage.h"
#include "json.h"
#include "jsonstore.h"

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
    va_list ap;
    fprintf(stderr, "FATAL ERROR: ");
    va_start(ap, p);
    vfprintf(stderr, p, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

void nonfatal(const char *p, ...)
{
    va_list ap;
    fprintf(stderr, "nonfatal: ");
    va_start(ap, p);
    vfprintf(stderr, p, ap);
    va_end(ap);
    fputc('\n', stderr);
}

char *x_get_default(const char *key) { return NULL; }

static void test_json(void)
{
    char *err = NULL;
    JsonValue *v;

    v = json_parse(PTRLEN_LITERAL(
        "\xEF\xBB\xBF { \"a\": [1, -2, true, false, null, \"x\\u00e9\\ud83d\\ude00\\n\"],"
        " \"b\": {}, \"a\": 3 }"), &err);
    CHECK(v && !err);
    if (v) {
        long long n;
        CHECK(json_object_len(v) == 2);    /* duplicate key replaced */
        CHECK(json_get_int(json_object_get(v, "a"), &n) && n == 3);
        json_free(v);
    }

    v = json_parse(PTRLEN_LITERAL("[\"x\\u00e9\\ud83d\\ude00\\n\", -9223372036854775808]"), &err);
    CHECK(v);
    if (v) {
        long long n;
        CHECK(!strcmp(json_get_string(json_array_get(v, 0)),
                      "x\xC3\xA9\xF0\x9F\x98\x80\n"));
        CHECK(json_get_int(json_array_get(v, 1), &n) && n == LLONG_MIN);
        json_free(v);
    }

    static const char *const bad[] = {
        "", "{", "[1,]", "{\"a\" 1}", "\"\\u0000\"", "\"\\ud800\"",
        "01", "1.5", "9223372036854775808", "tru", "[1] x", "\"a\nb\"",
        "{1:2}",
    };
    for (size_t i = 0; i < lenof(bad); i++) {
        err = NULL;
        v = json_parse(ptrlen_from_asciz(bad[i]), &err);
        CHECK(!v && err);
        if (v)
            fprintf(stderr, "  accepted bad input: %s\n", bad[i]);
        json_free(v);
        sfree(err);
    }

    /* Deep nesting must be rejected, not crash. */
    strbuf *deep = strbuf_new();
    for (int i = 0; i < 10000; i++)
        put_byte(deep, '[');
    err = NULL;
    v = json_parse(ptrlen_from_strbuf(deep), &err);
    CHECK(!v && err);
    sfree(err);
    strbuf_free(deep);

    /* Round trip through the writer. */
    JsonValue *obj = json_new_object();
    json_object_set(obj, "s", json_new_string("quote\" back\\ ctl\x01 tab\t"));
    json_object_set(obj, "n", json_new_int(-42));
    json_object_set(obj, "gone", json_new_bool(true));
    CHECK(json_object_delete(obj, "gone"));
    CHECK(!json_object_delete(obj, "gone"));
    strbuf *out = strbuf_new();
    json_write(obj, out);
    v = json_parse(ptrlen_from_strbuf(out), &err);
    CHECK(v);
    if (v) {
        CHECK(!strcmp(json_get_string(json_object_get(v, "s")),
                      "quote\" back\\ ctl\x01 tab\t"));
        CHECK(json_object_len(v) == 2);
        json_free(v);
    }
    strbuf_free(out);
    json_free(obj);
}

static bool session_listed(const char *name)
{
    bool found = false;
    strbuf *sb = strbuf_new();
    settings_e *e = enum_settings_start();
    while (strbuf_clear(sb), enum_settings_next(e, sb))
        if (!strcmp(sb->s, name))
            found = true;
    enum_settings_finish(e);
    strbuf_free(sb);
    return found;
}

static void test_sessions(void)
{
    static const char *const names[] = {
        "plain", "My Server", "CON", "nul.x", ".hidden", "a/b\\c:d",
        "caf\xC3\xA9", "Mixed", "mixed", "",
    };

    for (size_t i = 0; i < lenof(names); i++) {
        char *err = NULL;
        settings_w *w = open_settings_w(names[i], &err);
        CHECK(w && !err);
        write_setting_s(w, "HostName", names[i]);
        write_setting_i(w, "PortNumber", (int)i);
        write_setting_s(w, "Tricky", "a\"b\\c\nd");
        close_settings_w(w);
    }

    for (size_t i = 0; i < lenof(names); i++) {
        settings_r *r = open_settings_r(names[i]);
        CHECK(r);
        char *s = read_setting_s(r, "HostName");
        CHECK(s && !strcmp(s, names[i]));
        sfree(s);
        s = read_setting_s(r, "Tricky");
        CHECK(s && !strcmp(s, "a\"b\\c\nd"));
        sfree(s);
        CHECK(read_setting_i(r, "PortNumber", -1) == (int)i);
        /* Cross-type reads, as the old text formats allowed. */
        s = read_setting_s(r, "PortNumber");
        char *expect = dupprintf("%d", (int)i);
        CHECK(s && !strcmp(s, expect));
        sfree(expect);
        sfree(s);
        CHECK(read_setting_i(r, "Missing", 77) == 77);
        CHECK(read_setting_s(r, "Missing") == NULL);
        close_settings_r(r);

        CHECK(session_listed(*names[i] ? names[i] : "Default Settings"));
    }

    CHECK(open_settings_r("never saved") == NULL);

    del_settings("Mixed");
    CHECK(!session_listed("Mixed"));
    CHECK(session_listed("mixed"));
}

static void test_hostkeys(void)
{
    CHECK(check_stored_host_key("h.example", 22, "ssh-ed25519", "K1") == 1);
    CHECK(!have_ssh_host_key("h.example", 22, "ssh-ed25519"));
    store_host_key(NULL, "h.example", 22, "ssh-ed25519", "K1");
    store_host_key(NULL, "h.example", 2222, "ssh-ed25519", "K2");
    CHECK(check_stored_host_key("h.example", 22, "ssh-ed25519", "K1") == 0);
    CHECK(check_stored_host_key("h.example", 22, "ssh-ed25519", "XX") == 2);
    CHECK(check_stored_host_key("h.example", 2222, "ssh-ed25519", "K2") == 0);
    CHECK(check_stored_host_key("h.example", 22, "rsa2", "K1") == 1);
    CHECK(have_ssh_host_key("h.example", 22, "ssh-ed25519"));
    store_host_key(NULL, "h.example", 22, "ssh-ed25519", "K3");
    CHECK(check_stored_host_key("h.example", 22, "ssh-ed25519", "K3") == 0);
}

static void test_hostcas(void)
{
    host_ca *hca = host_ca_new();
    hca->name = dupstr("Corp CA");
    hca->ca_public_key = strbuf_new();
    put_datapl(hca->ca_public_key, PTRLEN_LITERAL("\x00\x01" "binary\xff"));
    hca->validity_expression = dupstr("*.corp.example || host.example");
    hca->opts.permit_rsa_sha1 = true;
    hca->opts.permit_rsa_sha512 = false;
    CHECK(host_ca_save(hca) == NULL);
    host_ca_free(hca);

    hca = host_ca_load("Corp CA");
    CHECK(hca);
    if (hca) {
        CHECK(hca->ca_public_key->len == 9 &&
              !memcmp(hca->ca_public_key->u, "\x00\x01" "binary\xff", 9));
        CHECK(!strcmp(hca->validity_expression,
                      "*.corp.example || host.example"));
        CHECK(hca->opts.permit_rsa_sha1);
        CHECK(!hca->opts.permit_rsa_sha512);
        host_ca_free(hca);
    }

    strbuf *sb = strbuf_new();
    host_ca_enum *e = enum_host_ca_start();
    CHECK(enum_host_ca_next(e, sb) && !strcmp(sb->s, "Corp CA"));
    enum_host_ca_finish(e);
    strbuf_free(sb);

    CHECK(host_ca_delete("Corp CA") == NULL);
    CHECK(host_ca_load("Corp CA") == NULL);
}

static strbuf *seed_read;
static void seed_consumer(void *data, int len)
{
    put_data(seed_read, data, len);
}

static void test_random_seed(void)
{
    write_random_seed("0123456789", 10);
    seed_read = strbuf_new();
    read_random_seed(seed_consumer);
    CHECK(seed_read->len == 10 && !memcmp(seed_read->u, "0123456789", 10));
    strbuf_free(seed_read);
}

static void test_corrupt_files(void)
{
    /* A corrupt host key cache must read as 'unknown' and not be
     * overwritten by store_host_key. */
    char *path = jsonstore_path("hostkeys.json");
    char *err = platform_write_file(path, "{ not json", 10);
    CHECK(!err);
    sfree(err);
    CHECK(check_stored_host_key("h.example", 22, "ssh-ed25519", "K3") == 1);
    store_host_key(NULL, "h.example", 22, "ssh-ed25519", "K4");
    strbuf *sb = platform_read_file(path);
    CHECK(sb && sb->len == 10);
    if (sb)
        strbuf_free(sb);
    platform_delete_file(path);
    sfree(path);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: test_jsonstore <scratch dir>\n");
        return 2;
    }
    setenv(JSONSTORE_DIR_ENV, argv[1], 1);

    test_json();
    test_sessions();
    test_hostkeys();
    test_hostcas();
    test_random_seed();
    test_corrupt_files();

    cleanup_all();
    platform_dir *d = platform_open_dir(argv[1]);
    CHECK(d == NULL);                  /* cleanup removed the directory */
    if (d)
        platform_close_dir(d);

    printf("%d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
