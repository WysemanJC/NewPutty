/*
 * test_regimport.c: tests for importing upstream PuTTY's registry
 * settings from a .reg export (regimport.c).
 *
 * Usage: test_regimport <empty scratch directory>
 *            run the tests, using the directory as $PUTTYDIR
 *        test_regimport <empty scratch directory> <file.reg>
 *            import a real export into the directory and report
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "putty.h"
#include "storage.h"
#include "jsonstore.h"
#include "regimport.h"

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

/* The text as UTF-16LE with a BOM, the way regedit writes it. */
static strbuf *utf16le(const char *text)
{
    strbuf *sb = strbuf_new();
    put_byte(sb, 0xFF);
    put_byte(sb, 0xFE);
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p == '\n') {
            put_byte(sb, '\r');
            put_byte(sb, 0);
        }
        put_byte(sb, *p);              /* ASCII only in these tests */
        put_byte(sb, 0);
    }
    return sb;
}

static const char sample[] =
    "Windows Registry Editor Version 5.00\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\SimonTatham]\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY]\n"
    "\"RandSeedFile\"=\"C:\\\\Users\\\\x\\\\putty.rnd\"\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Jumplist]\n"
    "\"Recent sessions\"=hex(7):61,00,00,00,00,00\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\"
    "Default%20Settings]\n"
    "\"HostName\"=\"\"\n"
    "\"PortNumber\"=dword:00000016\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\"
    "my%20host%20(jac)]\n"
    "\"HostName\"=\"host.example\"\n"
    "\"PortNumber\"=dword:00000016\n"
    "\"PublicKeyFile\"=\"C:\\\\keys\\\\a \\\"quoted\\\".ppk\"\n"
    "\"Blob\"=hex:01,02,\\\n"
    "  03\n"
    "\"Expand\"=hex(2):25,00,41,00,25,00,00,00\n"
    "\"Big\"=dword:ffffffff\n"
    "@=\"default value, ignored\"\n"
    "\"Broken\"=dword:xyz\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\existing]\n"
    "\"HostName\"=\"from-registry\"\n"
    "\n"
    "[hkey_current_user\\software\\simontatham\\putty\\sshhostkeys]\n"
    "\"ssh-ed25519@22:host.example\"=\"0x1,0x2\"\n"
    "\"rsa2@2222:old.example\"=\"0x10001,0xabc\"\n"
    "\"ssh-ed25519@22:known.example\"=\"registry-value\"\n"
    "\"junk\"=\"x\"\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\SshHostCAs\\My%20CA]\n"
    "\"PublicKey\"=\"AAAA\"\n"
    "\"MatchHosts\"=hex(7):2a,00,2e,00,65,00,78,00,00,00,00,00\n"
    "\"PermitRSASHA1\"=dword:00000001\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\SshHostCAs\\NoKey]\n"
    "\"Validity\"=\"*.example\"\n"
    "\n"
    "[HKEY_CURRENT_USER\\Software\\OtherApp\\Sessions\\ignored]\n"
    "\"HostName\"=\"nope\"\n"
    "\n"
    "[-HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\gone]\n";

static bool session_exists(const char *name)
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

static void test_import(void)
{
    /* Things that exist already, and must survive the import. */
    char *err = NULL;
    settings_w *w = open_settings_w("existing", &err);
    CHECK(w && !err);
    write_setting_s(w, "HostName", "local");
    close_settings_w(w);
    store_host_key(NULL, "known.example", 22, "ssh-ed25519", "local-value");

    strbuf *data = utf16le(sample);
    RegImportResult res;
    regimport_data(ptrlen_from_strbuf(data), &res);

    CHECK(res.ok);
    CHECK(res.sessions_added == 2);
    CHECK(res.sessions_existing == 1);
    CHECK(res.hostkeys_added == 2);
    CHECK(res.hostkeys_existing == 1);
    CHECK(res.cas_added == 1);
    CHECK(res.cas_existing == 0);
    CHECK(res.ignored == 2);           /* the hex: blob, the junk host key */
    CHECK(strstr(res.errors->s, "\"Broken\"") != NULL);
    CHECK(strstr(res.errors->s, "NoKey") != NULL);

    char *desc = regimport_describe(&res);
    CHECK(strstr(desc, "Saved sessions: 2 imported, 1 already existed"));
    CHECK(strstr(desc, "SSH host keys: 2 imported, 1 already existed"));
    sfree(desc);
    regimport_result_free(&res);

    /* Sessions: escaped names, string escapes, DWORDs, hex(2). */
    CHECK(session_exists("Default Settings"));
    CHECK(session_exists("my host (jac)"));
    CHECK(!session_exists("ignored"));
    CHECK(!session_exists("gone"));
    settings_r *r = open_settings_r("my host (jac)");
    CHECK(r);
    if (r) {
        char *s = read_setting_s(r, "HostName");
        CHECK(s && !strcmp(s, "host.example"));
        sfree(s);
        s = read_setting_s(r, "PublicKeyFile");
        CHECK(s && !strcmp(s, "C:\\keys\\a \"quoted\".ppk"));
        sfree(s);
        s = read_setting_s(r, "Expand");
        CHECK(s && !strcmp(s, "%A%"));
        sfree(s);
        CHECK(read_setting_i(r, "PortNumber", 0) == 22);
        CHECK(read_setting_i(r, "Big", 0) == -1);
        s = read_setting_s(r, "Blob");
        CHECK(!s);
        sfree(s);
        close_settings_r(r);
    }

    /* The existing session wasn't touched. */
    r = open_settings_r("existing");
    CHECK(r);
    if (r) {
        char *s = read_setting_s(r, "HostName");
        CHECK(s && !strcmp(s, "local"));
        sfree(s);
        close_settings_r(r);
    }

    /* Host keys: new ones added, the existing one kept. */
    CHECK(check_stored_host_key("host.example", 22, "ssh-ed25519",
                                "0x1,0x2") == 0);
    CHECK(check_stored_host_key("old.example", 2222, "rsa2",
                                "0x10001,0xabc") == 0);
    CHECK(check_stored_host_key("known.example", 22, "ssh-ed25519",
                                "local-value") == 0);

    /* Host CA, with MatchHosts converted to a validity expression. */
    host_ca *hca = host_ca_load("My CA");
    CHECK(hca);
    if (hca) {
        CHECK(hca->validity_expression &&
              strstr(hca->validity_expression, "*.ex"));
        CHECK(hca->opts.permit_rsa_sha1);
        CHECK(hca->ca_public_key && hca->ca_public_key->len == 3);
        host_ca_free(hca);
    }

    /* Importing again changes nothing. */
    regimport_data(ptrlen_from_strbuf(data), &res);
    CHECK(res.ok);
    CHECK(res.sessions_added == 0 && res.sessions_existing == 3);
    CHECK(res.hostkeys_added == 0 && res.hostkeys_existing == 3);
    CHECK(res.cas_added == 0 && res.cas_existing == 1);
    regimport_result_free(&res);
    strbuf_free(data);
}

static void test_other_formats(void)
{
    RegImportResult res;

    /* REGEDIT4 (ANSI/UTF-8), with a UTF-8 BOM. */
    regimport_data(PTRLEN_LITERAL(
        "\xEF\xBB\xBFREGEDIT4\r\n\r\n"
        "[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\"
        "regedit4]\r\n\"HostName\"=\"r4.example\"\r\n"), &res);
    CHECK(res.ok && res.sessions_added == 1);
    regimport_result_free(&res);
    CHECK(session_exists("regedit4"));

    /* Not a registry export at all. */
    regimport_data(PTRLEN_LITERAL("{\"not\": \"a reg file\"}\n"), &res);
    CHECK(!res.ok);
    char *desc = regimport_describe(&res);
    CHECK(strstr(desc, "Nothing was imported"));
    sfree(desc);
    regimport_result_free(&res);

    /* A registry export with nothing of PuTTY's in it. */
    regimport_data(PTRLEN_LITERAL(
        "Windows Registry Editor Version 5.00\r\n\r\n"
        "[HKEY_CURRENT_USER\\Software\\Other]\r\n\"a\"=\"b\"\r\n"), &res);
    CHECK(res.ok);
    desc = regimport_describe(&res);
    CHECK(strstr(desc, "No PuTTY settings were found"));
    sfree(desc);
    regimport_result_free(&res);

    /* Lots of problems: the summary lists only the first few. */
    {
        strbuf *many = strbuf_new();
        put_fmt(many, "REGEDIT4\n[" REGIMPORT_ROOT "\\Sessions\\x]\n");
        for (int i = 0; i < 25; i++)
            put_fmt(many, "\"bad%d\"=dword:zz\n", i);
        regimport_data(ptrlen_from_strbuf(many), &res);
        desc = regimport_describe(&res);
        CHECK(strstr(desc, "\"bad9\"") && !strstr(desc, "\"bad10\""));
        CHECK(strstr(desc, "...and 15 more."));
        sfree(desc);
        regimport_result_free(&res);
        strbuf_free(many);
    }

    /* Truncated UTF-16 and garbage must not crash. */
    for (size_t len = 0; len < 64; len++) {
        strbuf *d = utf16le(sample);
        regimport_data(make_ptrlen(d->u, len < d->len ? len : d->len), &res);
        regimport_result_free(&res);
        strbuf_free(d);
    }
}

static void set_puttydir(const char *dir)
{
#ifdef _WIN32
    _putenv_s(JSONSTORE_DIR_ENV, dir);
#else
    setenv(JSONSTORE_DIR_ENV, dir, 1);
#endif
}

int main(int argc, char **argv)
{
    if (argc != 2 && argc != 3) {
        fprintf(stderr, "usage: test_regimport <scratch dir> [<file.reg>]\n");
        return 2;
    }
    set_puttydir(argv[1]);

    if (argc == 3) {
        Filename *fn = filename_from_str(argv[2]);
        RegImportResult res;
        regimport_file(fn, &res);
        char *desc = regimport_describe(&res);
        printf("%s\n", desc);
        sfree(desc);
        int ret = res.ok ? 0 : 1;
        regimport_result_free(&res);
        filename_free(fn);
        return ret;
    }

    test_import();
    test_other_formats();

    printf("%d passed, %d failed\n", passes, fails);
    return fails ? 1 : 0;
}
