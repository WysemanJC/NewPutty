/*
 * regimport.c: import upstream PuTTY's settings from a Windows
 * registry export (.reg file) into the JSON store. See regimport.h.
 *
 * Only the text of the file is parsed, and everything is written
 * through the storage interface, so this is platform-independent: an
 * export made on one machine can be imported on any platform.
 *
 * What's imported, from under REGIMPORT_ROOT:
 *
 *   Sessions\<name>     -> one saved session each, values verbatim
 *                          (strings as strings, DWORDs as integers)
 *   SshHostKeys         -> the host key cache (same identifiers)
 *   SshHostCAs\<name>   -> one trusted host CA each
 *
 * Key names are escaped in the registry the way upstream PuTTY
 * escapes them ("%20" for a space, and so on), so they're unescaped
 * here. Anything that already exists is left exactly as it is.
 */

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "putty.h"
#include "storage.h"
#include "jsonstore.h"
#include "regimport.h"
#include "tree234.h"

/* Registry exports of PuTTY settings are a few MB at most. */
#define REGIMPORT_MAX_FILE (64 * 1024 * 1024)

typedef enum { RV_SZ, RV_DWORD, RV_MULTI_SZ } RegValueType;

typedef struct RegValue {
    char *name;
    RegValueType type;
    strbuf *data;       /* RV_SZ: the string; RV_MULTI_SZ: NUL-ended list */
    unsigned long dword;
} RegValue;

typedef struct RegKey {
    char *path;         /* relative to REGIMPORT_ROOT, e.g. "Sessions\\x" */
    RegValue *values;
    size_t nvalues, valuessize;
} RegKey;

typedef struct RegFile {
    RegKey *keys;
    size_t nkeys, keyssize;
} RegFile;

static void regfile_free(RegFile *rf)
{
    for (size_t i = 0; i < rf->nkeys; i++) {
        RegKey *k = &rf->keys[i];
        for (size_t j = 0; j < k->nvalues; j++) {
            sfree(k->values[j].name);
            if (k->values[j].data)
                strbuf_free(k->values[j].data);
        }
        sfree(k->values);
        sfree(k->path);
    }
    sfree(rf->keys);
}

static void add_error(RegImportResult *res, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    put_fmtv(res->errors, fmt, ap);
    va_end(ap);
    put_byte(res->errors, '\n');
}

/* ----------------------------------------------------------------------
 * Text handling.
 */

static void utf16_to_utf8(const unsigned char *p, size_t len, bool be,
                          strbuf *out)
{
    size_t i = 0;
    while (i + 1 < len) {
        unsigned c = be ? (p[i] << 8 | p[i+1]) : (p[i] | p[i+1] << 8);
        i += 2;
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < len) {
            unsigned c2 = be ? (p[i] << 8 | p[i+1]) : (p[i] | p[i+1] << 8);
            if (c2 >= 0xDC00 && c2 < 0xE000) {
                c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                i += 2;
            } else {
                c = 0xFFFD;
            }
        } else if (c >= 0xD800 && c < 0xE000) {
            c = 0xFFFD;                /* unpaired surrogate */
        }
        put_utf8_char(out, c);
    }
}

/*
 * The whole file as UTF-8. regedit writes UTF-16LE with a BOM; older
 * REGEDIT4 files are in the ANSI code page, which we pass through.
 */
static strbuf *file_text(ptrlen data)
{
    const unsigned char *p = data.ptr;
    size_t len = data.len;
    strbuf *sb = strbuf_new_nm();

    if (len >= 2 && ((p[0] == 0xFF && p[1] == 0xFE) ||
                     (p[0] == 0xFE && p[1] == 0xFF))) {
        utf16_to_utf8(p + 2, len - 2, p[0] == 0xFE, sb);
    } else {
        if (len >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) {
            p += 3;
            len -= 3;
        }
        put_data(sb, p, len);
    }
    return sb;
}

static char ascii_lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? c - 'A' + 'a' : c;
}

/* Does 's' start with 'prefix', ignoring ASCII case (as the registry
 * does)? If so, set *rest to what follows. */
static bool prefix_ci(ptrlen s, const char *prefix, ptrlen *rest)
{
    size_t n = strlen(prefix);
    if (s.len < n)
        return false;
    const char *p = s.ptr;
    for (size_t i = 0; i < n; i++)
        if (ascii_lower(p[i]) != ascii_lower(prefix[i]))
            return false;
    if (rest)
        *rest = make_ptrlen(p + n, s.len - n);
    return true;
}

static bool eq_ci(ptrlen s, const char *str)
{
    ptrlen rest;
    return prefix_ci(s, str, &rest) && rest.len == 0;
}

static ptrlen trim(ptrlen s)
{
    const char *p = s.ptr;
    size_t n = s.len;
    while (n && (*p == ' ' || *p == '\t')) {
        p++;
        n--;
    }
    while (n && (p[n-1] == ' ' || p[n-1] == '\t' || p[n-1] == '\r'))
        n--;
    return make_ptrlen(p, n);
}

static int hexdigit(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    c = ascii_lower(c);
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return -1;
}

/* Undo upstream PuTTY's escaping of registry key names ("%XX"). */
static char *unescape_key_name(ptrlen in)
{
    strbuf *sb = strbuf_new();
    const char *p = in.ptr;
    for (size_t i = 0; i < in.len; i++) {
        int h, l;
        if (p[i] == '%' && i + 2 < in.len &&
            (h = hexdigit(p[i+1])) >= 0 && (l = hexdigit(p[i+2])) >= 0) {
            put_byte(sb, h * 16 + l);
            i += 2;
        } else {
            put_byte(sb, p[i]);
        }
    }
    return strbuf_to_str(sb);
}

/* Parse a "quoted" string with regedit's \\ and \" escapes. On
 * success, *s is advanced past the closing quote. */
static bool parse_quoted(ptrlen *s, strbuf *out)
{
    const char *p = s->ptr;
    size_t n = s->len, i = 1;
    if (!n || p[0] != '"')
        return false;
    while (i < n) {
        char c = p[i++];
        if (c == '\\' && i < n) {
            put_byte(out, p[i++]);
        } else if (c == '"') {
            *s = make_ptrlen(p + i, n - i);
            return true;
        } else {
            put_byte(out, c);
        }
    }
    return false;
}

/* Parse the comma-separated hex bytes after "hex:" or "hex(N):". */
static bool parse_hex_bytes(ptrlen s, strbuf *out)
{
    const char *p = s.ptr;
    size_t n = s.len, i = 0;
    while (i < n) {
        while (i < n && (p[i] == ' ' || p[i] == '\t'))
            i++;
        if (i == n)
            break;
        int h = hexdigit(p[i]);
        if (h < 0)
            return false;
        unsigned v = h;
        i++;
        if (i < n && hexdigit(p[i]) >= 0)
            v = v * 16 + hexdigit(p[i++]);
        put_byte(out, v);
        while (i < n && (p[i] == ' ' || p[i] == '\t'))
            i++;
        if (i < n) {
            if (p[i] != ',')
                return false;
            i++;
        }
    }
    return true;
}

/* ----------------------------------------------------------------------
 * Parsing the file into keys and values.
 */

static void parse_value_line(ptrlen line, RegKey *key, RegImportResult *res)
{
    strbuf *name = strbuf_new();
    if (!parse_quoted(&line, name)) {
        add_error(res, "Malformed line ignored: %.*s",
                  PTRLEN_PRINTF(line));
        strbuf_free(name);
        return;
    }
    line = trim(line);
    if (!line.len || *(const char *)line.ptr != '=') {
        add_error(res, "Malformed value \"%s\" ignored", name->s);
        strbuf_free(name);
        return;
    }
    line = trim(make_ptrlen((const char *)line.ptr + 1, line.len - 1));

    RegValue v;
    memset(&v, 0, sizeof(v));
    ptrlen rest;
    bool ok = false, ignored = false;

    if (line.len && *(const char *)line.ptr == '"') {
        v.type = RV_SZ;
        v.data = strbuf_new();
        ok = parse_quoted(&line, v.data) && trim(line).len == 0;
    } else if (prefix_ci(line, "dword:", &rest)) {
        rest = trim(rest);
        const char *p = rest.ptr;
        v.type = RV_DWORD;
        ok = rest.len >= 1 && rest.len <= 8;
        for (size_t i = 0; ok && i < rest.len; i++) {
            int h = hexdigit(p[i]);
            if (h < 0)
                ok = false;
            else
                v.dword = v.dword * 16 + h;
        }
    } else if (prefix_ci(line, "hex(2):", &rest) ||
               prefix_ci(line, "hex(7):", &rest)) {
        bool multi = (ascii_lower(((const char *)line.ptr)[4]) == '7');
        strbuf *bytes = strbuf_new();
        if (parse_hex_bytes(rest, bytes)) {
            strbuf *text = strbuf_new();
            utf16_to_utf8(bytes->u, bytes->len, false, text);
            if (multi) {
                /* NUL-separated, with an empty string at the end. */
                v.type = RV_MULTI_SZ;
                v.data = text;
            } else {
                /* An expandable string: use it as a plain string. */
                v.type = RV_SZ;
                v.data = strbuf_new();
                put_dataz(v.data, text->s);   /* stops at the NUL */
                strbuf_free(text);
            }
            ok = true;
        }
        strbuf_free(bytes);
    } else {
        /* hex: (binary), hex(b): (QWORD), "-" (deletion), and so on:
         * PuTTY never stores these, so skip them. */
        ignored = true;
    }

    if (ignored) {
        res->ignored++;
        strbuf_free(name);
        return;
    }
    if (!ok) {
        add_error(res, "Malformed value \"%s\" ignored", name->s);
        if (v.data)
            strbuf_free(v.data);
        strbuf_free(name);
        return;
    }

    v.name = strbuf_to_str(name);
    sgrowarray(key->values, key->valuessize, key->nvalues);
    key->values[key->nvalues++] = v;
}

static bool parse_regfile(ptrlen text, RegFile *rf, RegImportResult *res)
{
    const char *p = text.ptr, *end = p + text.len;
    bool seen_header = false;
    RegKey *cur = NULL;
    strbuf *line = strbuf_new();

    while (p < end) {
        /* Gather one logical line, joining "\" continuations. */
        strbuf_clear(line);
        while (p < end) {
            const char *nl = memchr(p, '\n', end - p);
            const char *lend = nl ? nl : end;
            /* (Continuation lines are indented; trimming removes it.) */
            ptrlen phys = trim(make_ptrlen(p, lend - p));
            p = nl ? nl + 1 : end;
            put_datapl(line, phys);
            if (line->len && line->s[line->len - 1] == '\\' &&
                line->s[0] != '[') {
                strbuf_shrink_by(line, 1);
                continue;
            }
            break;
        }
        ptrlen l = ptrlen_from_strbuf(line);
        if (!l.len || line->s[0] == ';')
            continue;

        if (!seen_header) {
            if (!eq_ci(l, "Windows Registry Editor Version 5.00") &&
                !eq_ci(l, "REGEDIT4")) {
                add_error(res, "This is not a registry export file "
                          "(it doesn't start with \"Windows Registry "
                          "Editor Version 5.00\" or \"REGEDIT4\").");
                strbuf_free(line);
                return false;
            }
            seen_header = true;
            continue;
        }

        if (line->s[0] == '[') {
            cur = NULL;
            const char *close = strrchr(line->s, ']');
            if (!close || line->s[1] == '-')
                continue;              /* malformed, or a deletion */
            ptrlen path = make_ptrlen(line->s + 1, close - line->s - 1), rest;
            if (eq_ci(path, REGIMPORT_ROOT)) {
                rest = PTRLEN_LITERAL("");
            } else if (!prefix_ci(path, REGIMPORT_ROOT "\\", &rest)) {
                continue;              /* not PuTTY's: ignore it */
            }
            sgrowarray(rf->keys, rf->keyssize, rf->nkeys);
            cur = &rf->keys[rf->nkeys++];
            memset(cur, 0, sizeof(*cur));
            cur->path = mkstr(rest);
        } else if (line->s[0] == '"') {
            if (cur)
                parse_value_line(l, cur, res);
        } else if (line->s[0] == '@') {
            /* A key's default value: PuTTY doesn't use these. */
        } else if (cur) {
            add_error(res, "Malformed line ignored: %.*s",
                      PTRLEN_PRINTF(l));
        }
    }

    strbuf_free(line);
    if (!seen_header) {
        add_error(res, "The file is empty.");
        return false;
    }
    return true;
}

/* ----------------------------------------------------------------------
 * Writing what we found to the JSON store.
 */

/* If 'path' is "<parent>\<child>" (one level down), return the child. */
static bool child_of(const char *path, const char *parent, ptrlen *child)
{
    ptrlen rest;
    if (!prefix_ci(ptrlen_from_asciz(path), parent, &rest) ||
        !rest.len || *(const char *)rest.ptr != '\\')
        return false;
    rest = make_ptrlen((const char *)rest.ptr + 1, rest.len - 1);
    if (!rest.len || memchr(rest.ptr, '\\', rest.len))
        return false;
    *child = rest;
    return true;
}

static const RegValue *find_value(const RegKey *k, const char *name,
                                  RegValueType type)
{
    for (size_t i = 0; i < k->nvalues; i++)
        if (k->values[i].type == type &&
            eq_ci(ptrlen_from_asciz(k->values[i].name), name))
            return &k->values[i];
    return NULL;
}

static int strcmp_cmp(void *av, void *bv)
{
    return strcmp((const char *)av, (const char *)bv);
}

static void free_name_tree(tree234 *t)
{
    char *s;
    while ((s = delpos234(t, 0)) != NULL)
        sfree(s);
    freetree234(t);
}

static void import_sessions(RegFile *rf, RegImportResult *res)
{
    tree234 *have = newtree234(strcmp_cmp);
    strbuf *sb = strbuf_new();
    settings_e *e = enum_settings_start();
    if (e) {
        while (strbuf_clear(sb), enum_settings_next(e, sb))
            add234(have, dupstr(sb->s));
        enum_settings_finish(e);
    }
    strbuf_free(sb);

    for (size_t i = 0; i < rf->nkeys; i++) {
        const RegKey *k = &rf->keys[i];
        ptrlen munged;
        if (!child_of(k->path, "Sessions", &munged))
            continue;
        char *name = unescape_key_name(munged);
        if (!*name || find234(have, name, NULL)) {
            if (*name)
                res->sessions_existing++;
            sfree(name);
            continue;
        }

        char *errmsg = NULL;
        settings_w *h = open_settings_w(name, &errmsg);
        if (!h) {
            add_error(res, "Session \"%s\" not imported: %s", name,
                      errmsg ? errmsg : "unable to save it");
            sfree(errmsg);
            sfree(name);
            continue;
        }
        for (size_t j = 0; j < k->nvalues; j++) {
            const RegValue *v = &k->values[j];
            if (v->type == RV_SZ)
                write_setting_s(h, v->name, v->data->s);
            else if (v->type == RV_DWORD)
                write_setting_i(h, v->name, (int)v->dword);
            else
                res->ignored++;
        }
        close_settings_w(h);
        res->sessions_added++;
        add234(have, name);            /* the tree now owns 'name' */
    }
    free_name_tree(have);
}

static void import_host_keys(RegFile *rf, RegImportResult *res)
{
    char **ids = NULL, **keys = NULL;
    size_t n = 0, size = 0, keysize = 0;

    for (size_t i = 0; i < rf->nkeys; i++) {
        const RegKey *k = &rf->keys[i];
        if (!eq_ci(ptrlen_from_asciz(k->path), "SshHostKeys"))
            continue;
        for (size_t j = 0; j < k->nvalues; j++) {
            const RegValue *v = &k->values[j];
            /* Identifiers look like "ssh-ed25519@22:host.example". */
            const char *at = strchr(v->name, '@');
            if (v->type != RV_SZ || !at || at == v->name ||
                !strchr(at, ':')) {
                res->ignored++;
                continue;
            }
            sgrowarray(ids, size, n);
            sgrowarray(keys, keysize, n);
            ids[n] = v->name;
            keys[n] = v->data->s;
            n++;
        }
    }

    if (n) {
        char *err = jsonstore_add_host_keys(
            n, (const char *const *)ids, (const char *const *)keys,
            &res->hostkeys_added, &res->hostkeys_existing);
        if (err) {
            add_error(res, "SSH host keys not imported: %s", err);
            sfree(err);
        }
    }
    sfree(ids);
    sfree(keys);
}

static void import_host_cas(RegFile *rf, RegImportResult *res)
{
    tree234 *have = newtree234(strcmp_cmp);
    strbuf *sb = strbuf_new();
    host_ca_enum *e = enum_host_ca_start();
    if (e) {
        while (strbuf_clear(sb), enum_host_ca_next(e, sb))
            add234(have, dupstr(sb->s));
        enum_host_ca_finish(e);
    }
    strbuf_free(sb);

    for (size_t i = 0; i < rf->nkeys; i++) {
        const RegKey *k = &rf->keys[i];
        ptrlen munged;
        if (!child_of(k->path, "SshHostCAs", &munged))
            continue;
        char *name = unescape_key_name(munged);
        if (!*name || find234(have, name, NULL)) {
            if (*name)
                res->cas_existing++;
            sfree(name);
            continue;
        }

        const RegValue *pk = find_value(k, "PublicKey", RV_SZ);
        if (!pk) {
            add_error(res, "Host CA \"%s\" not imported: it has no "
                      "public key", name);
            sfree(name);
            continue;
        }

        host_ca *hca = host_ca_new();
        hca->name = dupstr(name);
        hca->ca_public_key = base64_decode_sb(ptrlen_from_asciz(pk->data->s));

        const RegValue *v;
        if ((v = find_value(k, "Validity", RV_SZ)) != NULL) {
            hca->validity_expression = dupstr(v->data->s);
        } else if ((v = find_value(k, "MatchHosts", RV_MULTI_SZ)) != NULL) {
            /* Older PuTTY: a list of wildcards, converted the same way
             * upstream converts it when loading from the registry. */
            CertExprBuilder *eb = cert_expr_builder_new();
            const char *wc = v->data->s, *wend = wc + v->data->len;
            while (wc < wend && *wc) {
                cert_expr_builder_add(eb, wc);
                wc += strlen(wc) + 1;
            }
            hca->validity_expression = cert_expr_expression(eb);
            cert_expr_builder_free(eb);
        }
        if ((v = find_value(k, "PermitRSASHA1", RV_DWORD)) != NULL)
            hca->opts.permit_rsa_sha1 = (v->dword != 0);
        if ((v = find_value(k, "PermitRSASHA256", RV_DWORD)) != NULL)
            hca->opts.permit_rsa_sha256 = (v->dword != 0);
        if ((v = find_value(k, "PermitRSASHA512", RV_DWORD)) != NULL)
            hca->opts.permit_rsa_sha512 = (v->dword != 0);

        char *err = host_ca_save(hca);
        host_ca_free(hca);
        if (err) {
            add_error(res, "Host CA \"%s\" not imported: %s", name, err);
            sfree(err);
            sfree(name);
            continue;
        }
        res->cas_added++;
        add234(have, name);            /* the tree now owns 'name' */
    }
    free_name_tree(have);
}

/* ----------------------------------------------------------------------
 * Public entry points.
 */

static void result_init(RegImportResult *res)
{
    memset(res, 0, sizeof(*res));
    res->ok = true;
    res->errors = strbuf_new();
}

static void import_text(ptrlen data, RegImportResult *res)
{
    strbuf *text = file_text(data);
    RegFile rf;
    memset(&rf, 0, sizeof(rf));

    if (parse_regfile(ptrlen_from_strbuf(text), &rf, res)) {
        import_sessions(&rf, res);
        import_host_keys(&rf, res);
        import_host_cas(&rf, res);
    } else {
        res->ok = false;
    }

    regfile_free(&rf);
    strbuf_free(text);
}

void regimport_data(ptrlen data, RegImportResult *res)
{
    result_init(res);
    import_text(data, res);
}

void regimport_file(const Filename *fn, RegImportResult *res)
{
    result_init(res);

    FILE *fp = f_open(fn, "rb", false);
    if (!fp) {
        add_error(res, "Unable to open %s", filename_to_str(fn));
        res->ok = false;
        return;
    }

    strbuf *data = strbuf_new_nm();
    char buf[16384];
    size_t got;
    bool too_big = false;
    while ((got = fread(buf, 1, sizeof(buf), fp)) > 0) {
        put_data(data, buf, got);
        if (data->len > REGIMPORT_MAX_FILE) {
            too_big = true;
            break;
        }
    }
    bool read_error = ferror(fp);
    fclose(fp);

    if (too_big || read_error) {
        add_error(res, too_big ? "%s is too large to be a registry "
                  "export of PuTTY's settings" : "Unable to read %s",
                  filename_to_str(fn));
        res->ok = false;
    } else {
        import_text(ptrlen_from_strbuf(data), res);
    }
    strbuf_free(data);
}

/* The first few error lines, so that a message box stays a sensible
 * size however badly an import goes. */
#define REGIMPORT_MAX_ERROR_LINES 10

static void put_error_lines(strbuf *sb, const strbuf *errors)
{
    const char *p = errors->s, *end = p + errors->len;
    size_t shown = 0, total = 0;
    for (const char *q = p; q < end; q++)
        if (*q == '\n')
            total++;
    while (p < end && shown < REGIMPORT_MAX_ERROR_LINES) {
        const char *nl = memchr(p, '\n', end - p);
        const char *lend = nl ? nl + 1 : end;
        put_data(sb, p, lend - p);
        p = lend;
        shown++;
    }
    if (total > shown)
        put_fmt(sb, "...and %"SIZEu" more.\n", total - shown);
}

char *regimport_describe(const RegImportResult *res)
{
    strbuf *sb = strbuf_new();

    if (!res->ok) {
        put_fmt(sb, "Nothing was imported.\n\n");
        put_error_lines(sb, res->errors);
        return strbuf_to_str(sb);
    }

    size_t found = res->sessions_added + res->sessions_existing +
        res->hostkeys_added + res->hostkeys_existing +
        res->cas_added + res->cas_existing;
    if (!found && !res->errors->len) {
        put_fmt(sb, "No PuTTY settings were found in this file. (They "
                "are expected under " REGIMPORT_ROOT ".)");
        return strbuf_to_str(sb);
    }

    put_fmt(sb, "Saved sessions: %"SIZEu" imported, %"SIZEu" already "
            "existed (left unchanged)\n",
            res->sessions_added, res->sessions_existing);
    put_fmt(sb, "SSH host keys: %"SIZEu" imported, %"SIZEu" already "
            "existed (left unchanged)\n",
            res->hostkeys_added, res->hostkeys_existing);
    put_fmt(sb, "Trusted host CAs: %"SIZEu" imported, %"SIZEu" already "
            "existed (left unchanged)\n",
            res->cas_added, res->cas_existing);
    if (res->ignored)
        put_fmt(sb, "\n%"SIZEu" registry value(s) of kinds PuTTY doesn't "
                "use were ignored.\n", res->ignored);
    if (res->errors->len) {
        put_fmt(sb, "\nProblems:\n");
        put_error_lines(sb, res->errors);
    }
    return strbuf_to_str(sb);
}

void regimport_result_free(RegImportResult *res)
{
    if (res->errors)
        strbuf_free(res->errors);
    res->errors = NULL;
}
