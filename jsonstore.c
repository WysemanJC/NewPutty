/*
 * jsonstore.c: platform-independent implementation of storage.h,
 * keeping all of PuTTY's persistent data in JSON files under a
 * per-user configuration directory. See jsonstore.h for the layout.
 *
 * The platform supplies a handful of filesystem primitives (see the
 * second half of jsonstore.h); everything else lives here, so that
 * Windows, macOS and Linux read and write identical files.
 */

#include <assert.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "putty.h"
#include "storage.h"
#include "jsonstore.h"

#define SESSIONS_DIR "sessions"
#define HOSTCAS_DIR "hostcas"
#define HOSTKEYS_FILE "hostkeys.json"
#define RANDSEED_FILE "randomseed"
#define JSON_EXT ".json"

#define FORMAT_SESSION "putty-session"
#define FORMAT_HOSTKEYS "putty-hostkeys"
#define FORMAT_HOSTCA "putty-hostca"
#define FORMAT_VERSION 1

/* ----------------------------------------------------------------------
 * Paths and whole-file helpers.
 */

char *jsonstore_dir(void)
{
    char *env = platform_getenv_utf8(JSONSTORE_DIR_ENV);
    if (env && *env)
        return env;
    sfree(env);
    return platform_default_config_dir();
}

char *jsonstore_path(const char *leaf)
{
    char *dir = jsonstore_dir();
    char *path = dupprintf("%s/%s", dir, leaf);
    sfree(dir);
    return path;
}

JsonValue *jsonstore_load(const char *leaf, char **err)
{
    if (err)
        *err = NULL;

    char *path = jsonstore_path(leaf);
    strbuf *sb = platform_read_file(path);
    if (!sb) {
        sfree(path);
        return NULL;
    }

    char *perr = NULL;
    JsonValue *v = json_parse(ptrlen_from_strbuf(sb), &perr);
    strbuf_free(sb);
    if (!v && err)
        *err = dupprintf("%s: %s", path, perr);
    sfree(perr);
    sfree(path);
    return v;
}

static char *jsonstore_make_parent_dirs(const char *leaf)
{
    char *dir = jsonstore_dir();
    char *err = platform_make_dir(dir);

    const char *slash = strrchr(leaf, '/');
    if (!err && slash) {
        char *sub = dupprintf("%s/%.*s", dir, (int)(slash - leaf), leaf);
        err = platform_make_dir(sub);
        sfree(sub);
    }
    sfree(dir);
    return err;
}

char *jsonstore_save(const char *leaf, const JsonValue *v)
{
    char *err = jsonstore_make_parent_dirs(leaf);
    if (err)
        return err;

    strbuf *sb = strbuf_new();
    json_write(v, sb);
    char *path = jsonstore_path(leaf);
    err = platform_write_file(path, sb->s, sb->len);
    sfree(path);
    strbuf_free(sb);
    return err;
}

/*
 * Wrap a payload in the common envelope:
 *   { "format": ..., "version": 1, ...payload members... }
 */
static JsonValue *new_envelope(const char *format)
{
    JsonValue *obj = json_new_object();
    json_object_set(obj, "format", json_new_string(format));
    json_object_set(obj, "version", json_new_int(FORMAT_VERSION));
    return obj;
}

static bool check_envelope(const JsonValue *obj, const char *format)
{
    if (!obj || json_type(obj) != JSON_OBJECT)
        return false;
    const char *f = json_get_string(json_object_get(obj, "format"));
    /* A missing format tag is tolerated, for hand-written files. */
    return !f || !strcmp(f, format);
}

/* ----------------------------------------------------------------------
 * Encoding names (sessions, CAs) as file names.
 *
 * Only lower-case letters, digits and "-_.@+" pass through; everything
 * else becomes %XX. Escaping upper case means two names differing only
 * in case can't collide on case-insensitive filesystems (Windows,
 * default macOS), and a leading '.' is escaped so no file is hidden.
 * Windows reserved device names (CON, NUL, COM1...) are made safe by
 * escaping their first character.
 */

static const char hexdigits[16] = "0123456789ABCDEF";

static bool is_reserved_device_name(const char *name)
{
    static const char *const reserved[] = {
        "con", "prn", "aux", "nul",
    };
    size_t len = strcspn(name, ".");
    for (size_t i = 0; i < lenof(reserved); i++)
        if (len == 3 && !strncmp(name, reserved[i], 3))
            return true;
    if (len == 4 && (!strncmp(name, "com", 3) || !strncmp(name, "lpt", 3)) &&
        name[3] >= '0' && name[3] <= '9')
        return true;
    return false;
}

static void encode_name(const char *in, strbuf *out)
{
    bool reserved = is_reserved_device_name(in);
    for (const char *p = in; *p; p++) {
        unsigned char c = *p;
        bool safe = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '@' || c == '+';
        if (p == in && (c == '.' || reserved))
            safe = false;
        if (safe) {
            put_byte(out, c);
        } else {
            put_byte(out, '%');
            put_byte(out, hexdigits[c >> 4]);
            put_byte(out, hexdigits[c & 15]);
        }
    }
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static void decode_name(ptrlen in, strbuf *out)
{
    const char *p = in.ptr, *end = p + in.len;
    while (p < end) {
        int hi, lo;
        if (*p == '%' && end - p >= 3 &&
            (hi = hexval(p[1])) >= 0 && (lo = hexval(p[2])) >= 0) {
            put_byte(out, (hi << 4) | lo);
            p += 3;
        } else {
            put_byte(out, *p++);
        }
    }
}

static char *named_file_leaf(const char *dir, const char *name)
{
    strbuf *sb = strbuf_new();
    put_fmt(sb, "%s/", dir);
    encode_name(name, sb);
    put_dataz(sb, JSON_EXT);
    return strbuf_to_str(sb);
}

/*
 * Enumerate "<dir>/*.json", yielding decoded names in sorted order
 * (directory order varies between platforms and filesystems).
 */
typedef struct named_enum {
    char **names;
    size_t n, size, pos;
} named_enum;

static int named_enum_cmp(const void *av, const void *bv)
{
    return strcmp(*(char *const *)av, *(char *const *)bv);
}

static named_enum *named_enum_start(const char *dir)
{
    named_enum *e = snew(named_enum);
    e->names = NULL;
    e->n = e->size = e->pos = 0;

    char *path = jsonstore_path(dir);
    platform_dir *d = platform_open_dir(path);
    sfree(path);
    if (!d)
        return e;

    char *leaf;
    strbuf *sb = strbuf_new();
    while ((leaf = platform_read_dir(d)) != NULL) {
        ptrlen pl = ptrlen_from_asciz(leaf);
        if (pl.len > strlen(JSON_EXT) && leaf[0] != '.' &&
            ptrlen_endswith(pl, PTRLEN_LITERAL(JSON_EXT), &pl)) {
            strbuf_clear(sb);
            decode_name(pl, sb);
            sgrowarray(e->names, e->size, e->n);
            e->names[e->n++] = dupstr(sb->s);
        }
        sfree(leaf);
    }
    strbuf_free(sb);
    platform_close_dir(d);

    qsort(e->names, e->n, sizeof(*e->names), named_enum_cmp);
    return e;
}

static bool named_enum_next(named_enum *e, strbuf *out)
{
    if (e->pos >= e->n)
        return false;
    put_dataz(out, e->names[e->pos++]);
    return true;
}

static void named_enum_finish(named_enum *e)
{
    for (size_t i = 0; i < e->n; i++)
        sfree(e->names[i]);
    sfree(e->names);
    sfree(e);
}

/* ----------------------------------------------------------------------
 * Saved sessions.
 */

static const char *session_or_default(const char *sessionname)
{
    return (sessionname && *sessionname) ? sessionname : "Default Settings";
}

struct settings_w {
    char *name;
    JsonValue *settings;
};

settings_w *open_settings_w(const char *sessionname, char **errmsg)
{
    *errmsg = NULL;
    sessionname = session_or_default(sessionname);

    /* Create the directories now, so that failure is reported here. */
    char *err = jsonstore_make_parent_dirs(SESSIONS_DIR "/x");
    if (err) {
        *errmsg = dupprintf("Unable to save session: %s", err);
        sfree(err);
        return NULL;
    }

    settings_w *handle = snew(settings_w);
    handle->name = dupstr(sessionname);
    handle->settings = json_new_object();
    return handle;
}

void write_setting_s(settings_w *handle, const char *key, const char *value)
{
    if (handle)
        json_object_set(handle->settings, key, json_new_string(value));
}

void write_setting_i(settings_w *handle, const char *key, int value)
{
    if (handle)
        json_object_set(handle->settings, key, json_new_int(value));
}

void close_settings_w(settings_w *handle)
{
    JsonValue *doc = new_envelope(FORMAT_SESSION);
    json_object_set(doc, "name", json_new_string(handle->name));
    json_object_set(doc, "settings", handle->settings);

    char *leaf = named_file_leaf(SESSIONS_DIR, handle->name);
    char *err = jsonstore_save(leaf, doc);
    if (err) {
        /* The storage.h interface gives us no way to return this. */
        nonfatal("Unable to save session: %s", err);
        sfree(err);
    }
    sfree(leaf);
    json_free(doc);
    sfree(handle->name);
    sfree(handle);
}

struct settings_r {
    JsonValue *doc;
    JsonValue *settings;               /* borrowed from doc */
};

settings_r *open_settings_r(const char *sessionname)
{
    sessionname = session_or_default(sessionname);
    char *leaf = named_file_leaf(SESSIONS_DIR, sessionname);
    char *err = NULL;
    JsonValue *doc = jsonstore_load(leaf, &err);
    sfree(leaf);

    if (err) {
        nonfatal("Unable to load session \"%s\": %s", sessionname, err);
        sfree(err);
    }
    if (!doc)
        return NULL;

    JsonValue *settings = json_object_get(doc, "settings");
    if (!check_envelope(doc, FORMAT_SESSION) || !settings ||
        json_type(settings) != JSON_OBJECT) {
        json_free(doc);
        return NULL;
    }

    settings_r *handle = snew(settings_r);
    handle->doc = doc;
    handle->settings = settings;
    return handle;
}

char *read_setting_s(settings_r *handle, const char *key)
{
    JsonValue *v = handle ? json_object_get(handle->settings, key) : NULL;
    if (v) {
        const char *s = json_get_string(v);
        long long n;
        if (s)
            return dupstr(s);
        if (json_get_int(v, &n))
            return dupprintf("%lld", n);
        return NULL;
    }

    const char *fallback = platform_setting_fallback(key);
    return fallback ? dupstr(fallback) : NULL;
}

int read_setting_i(settings_r *handle, const char *key, int defvalue)
{
    JsonValue *v = handle ? json_object_get(handle->settings, key) : NULL;
    if (v) {
        long long n;
        bool b;
        const char *s;
        if (json_get_int(v, &n))
            return (n < INT_MIN || n > INT_MAX) ? defvalue : (int)n;
        if (json_get_bool(v, &b))
            return b;
        if ((s = json_get_string(v)) != NULL)
            return atoi(s);
        return defvalue;
    }

    const char *fallback = platform_setting_fallback(key);
    return fallback ? atoi(fallback) : defvalue;
}

void close_settings_r(settings_r *handle)
{
    if (!handle)
        return;
    json_free(handle->doc);
    sfree(handle);
}

void del_settings(const char *sessionname)
{
    char *leaf = named_file_leaf(SESSIONS_DIR,
                                 session_or_default(sessionname));
    char *path = jsonstore_path(leaf);
    platform_delete_file(path);
    sfree(path);
    sfree(leaf);
}

struct settings_e {
    named_enum *e;
};

settings_e *enum_settings_start(void)
{
    settings_e *handle = snew(settings_e);
    handle->e = named_enum_start(SESSIONS_DIR);
    return handle;
}

bool enum_settings_next(settings_e *handle, strbuf *out)
{
    return named_enum_next(handle->e, out);
}

void enum_settings_finish(settings_e *handle)
{
    named_enum_finish(handle->e);
    sfree(handle);
}

/* ----------------------------------------------------------------------
 * Host key cache.
 *
 * hostkeys.json looks like
 *
 *   { "format": "putty-hostkeys", "version": 1,
 *     "keys": { "ssh-ed25519@22:host.example.org": "0x...,0x...", ... } }
 *
 * The identifiers and key strings are exactly those PuTTY has always
 * used, so existing caches can be imported verbatim.
 */

static char *hostkey_id(const char *hostname, int port, const char *keytype)
{
    return dupprintf("%s@%d:%s", keytype, port, hostname);
}

static JsonValue *load_hostkeys(char **err)
{
    JsonValue *doc = jsonstore_load(HOSTKEYS_FILE, err);
    if (doc && !check_envelope(doc, FORMAT_HOSTKEYS)) {
        json_free(doc);
        doc = NULL;
    }
    return doc;
}

int check_stored_host_key(const char *hostname, int port,
                          const char *keytype, const char *key)
{
    char *err = NULL;
    JsonValue *doc = load_hostkeys(&err);
    if (err) {
        /*
         * Treat an unreadable cache as "key not known", so that the
         * user is prompted rather than silently trusting anything.
         *
         * Don't report the error here: we're called in the middle of
         * handling network data, where a modal message box would let
         * the GUI's message loop re-enter the SSH code. If the user
         * accepts the key, store_host_key reports the problem through
         * the Seat, as it refuses to overwrite a cache it can't read.
         */
        sfree(err);
    }
    if (!doc)
        return 1;

    char *id = hostkey_id(hostname, port, keytype);
    const char *stored = json_get_string(
        json_object_get(json_object_get(doc, "keys"), id));
    int ret = !stored ? 1 : !strcmp(stored, key) ? 0 : 2;
    sfree(id);
    json_free(doc);
    return ret;
}

bool have_ssh_host_key(const char *hostname, int port, const char *keytype)
{
    /*
     * If we have a host key, check_stored_host_key will return 0 or 2.
     * If we don't have one, it'll return 1.
     */
    return check_stored_host_key(hostname, port, keytype, "") != 1;
}

static void store_host_key_error(Seat *seat, const char *err)
{
    if (seat)
        seat_nonfatal(seat, "Unable to store host key: %s", err);
    else
        nonfatal("Unable to store host key: %s", err);
}

void store_host_key(Seat *seat, const char *hostname, int port,
                    const char *keytype, const char *key)
{
    char *err = NULL;
    JsonValue *doc = load_hostkeys(&err);
    if (err) {
        /* Refuse to overwrite a cache we couldn't parse. */
        store_host_key_error(seat, err);
        sfree(err);
        return;
    }
    if (!doc)
        doc = new_envelope(FORMAT_HOSTKEYS);

    JsonValue *keys = json_object_get(doc, "keys");
    if (!keys || json_type(keys) != JSON_OBJECT) {
        keys = json_new_object();
        json_object_set(doc, "keys", keys);
    }

    char *id = hostkey_id(hostname, port, keytype);
    json_object_set(keys, id, json_new_string(key));
    sfree(id);

    if ((err = jsonstore_save(HOSTKEYS_FILE, doc)) != NULL) {
        store_host_key_error(seat, err);
        sfree(err);
    }
    json_free(doc);
}

/* ----------------------------------------------------------------------
 * Trusted host certification authorities.
 *
 * hostcas/<name>.json looks like
 *
 *   { "format": "putty-hostca", "version": 1, "name": "...",
 *     "public_key": "<base64>", "validity": "<expression>",
 *     "permit_rsa_sha1": false, "permit_rsa_sha256": true,
 *     "permit_rsa_sha512": true }
 */

struct host_ca_enum {
    named_enum *e;
};

host_ca_enum *enum_host_ca_start(void)
{
    host_ca_enum *handle = snew(host_ca_enum);
    handle->e = named_enum_start(HOSTCAS_DIR);
    return handle;
}

bool enum_host_ca_next(host_ca_enum *handle, strbuf *out)
{
    return named_enum_next(handle->e, out);
}

void enum_host_ca_finish(host_ca_enum *handle)
{
    named_enum_finish(handle->e);
    sfree(handle);
}

static void load_bool(JsonValue *doc, const char *key, bool *out)
{
    bool b;
    long long n;
    JsonValue *v = json_object_get(doc, key);
    if (json_get_bool(v, &b))
        *out = b;
    else if (json_get_int(v, &n))
        *out = (n != 0);
}

host_ca *host_ca_load(const char *name)
{
    char *leaf = named_file_leaf(HOSTCAS_DIR, name);
    char *err = NULL;
    JsonValue *doc = jsonstore_load(leaf, &err);
    sfree(leaf);
    if (err) {
        nonfatal("Unable to load CA record \"%s\": %s", name, err);
        sfree(err);
    }
    if (!doc)
        return NULL;
    if (!check_envelope(doc, FORMAT_HOSTCA)) {
        json_free(doc);
        return NULL;
    }

    host_ca *hca = host_ca_new();
    hca->name = dupstr(name);

    const char *s;
    if ((s = json_get_string(json_object_get(doc, "public_key"))) != NULL)
        hca->ca_public_key = base64_decode_sb(ptrlen_from_asciz(s));
    if ((s = json_get_string(json_object_get(doc, "validity"))) != NULL)
        hca->validity_expression = dupstr(s);

    load_bool(doc, "permit_rsa_sha1", &hca->opts.permit_rsa_sha1);
    load_bool(doc, "permit_rsa_sha256", &hca->opts.permit_rsa_sha256);
    load_bool(doc, "permit_rsa_sha512", &hca->opts.permit_rsa_sha512);

    json_free(doc);
    return hca;
}

char *host_ca_save(host_ca *hca)
{
    if (!*hca->name)
        return dupstr("CA record must have a name");

    JsonValue *doc = new_envelope(FORMAT_HOSTCA);
    json_object_set(doc, "name", json_new_string(hca->name));

    strbuf *b64 = base64_encode_sb(ptrlen_from_strbuf(hca->ca_public_key), 0);
    json_object_set(doc, "public_key", json_new_string(b64->s));
    strbuf_free(b64);

    json_object_set(doc, "validity", json_new_string(
                        hca->validity_expression ?
                        hca->validity_expression : ""));
    json_object_set(doc, "permit_rsa_sha1",
                    json_new_bool(hca->opts.permit_rsa_sha1));
    json_object_set(doc, "permit_rsa_sha256",
                    json_new_bool(hca->opts.permit_rsa_sha256));
    json_object_set(doc, "permit_rsa_sha512",
                    json_new_bool(hca->opts.permit_rsa_sha512));

    char *leaf = named_file_leaf(HOSTCAS_DIR, hca->name);
    char *err = jsonstore_save(leaf, doc);
    sfree(leaf);
    json_free(doc);

    if (err) {
        char *msg = dupprintf("Unable to save CA record: %s", err);
        sfree(err);
        return msg;
    }
    return NULL;
}

char *host_ca_delete(const char *name)
{
    if (!*name)
        return dupstr("CA record must have a name");
    char *leaf = named_file_leaf(HOSTCAS_DIR, name);
    char *path = jsonstore_path(leaf);
    char *err = NULL;
    if (!platform_delete_file(path))
        err = dupprintf("Unable to delete file '%s'", path);
    sfree(path);
    sfree(leaf);
    return err;
}

/* ----------------------------------------------------------------------
 * Random seed.
 */

void read_random_seed(noise_consumer_t consumer)
{
    char *path = jsonstore_path(RANDSEED_FILE);
    strbuf *sb = platform_read_file(path);
    sfree(path);
    if (sb) {
        if (sb->len)
            consumer(sb->u, sb->len);
        strbuf_free(sb);
    }
}

void write_random_seed(void *data, int len)
{
    char *err = jsonstore_make_parent_dirs(RANDSEED_FILE);
    if (!err) {
        char *path = jsonstore_path(RANDSEED_FILE);
        err = platform_write_file(path, data, len);
        sfree(path);
    }
    if (err) {
        nonfatal("Unable to write random seed: %s", err);
        sfree(err);
    }
}

/* ----------------------------------------------------------------------
 * Remove everything this module stores. The configuration directory
 * itself is removed too if that leaves it empty.
 */

static void delete_named_dir(const char *dir)
{
    char *dirpath = jsonstore_path(dir);
    platform_dir *d = platform_open_dir(dirpath);
    if (d) {
        char *leaf;
        while ((leaf = platform_read_dir(d)) != NULL) {
            ptrlen pl = ptrlen_from_asciz(leaf);
            if (ptrlen_endswith(pl, PTRLEN_LITERAL(JSON_EXT), NULL)) {
                char *path = dupprintf("%s/%s", dirpath, leaf);
                platform_delete_file(path);
                sfree(path);
            }
            sfree(leaf);
        }
        platform_close_dir(d);
    }
    platform_delete_dir(dirpath);
    sfree(dirpath);
}

void jsonstore_cleanup_all(void)
{
    static const char *const files[] = {
        HOSTKEYS_FILE, RANDSEED_FILE, "jumplist.json",
    };

    delete_named_dir(SESSIONS_DIR);
    delete_named_dir(HOSTCAS_DIR);
    for (size_t i = 0; i < lenof(files); i++) {
        char *path = jsonstore_path(files[i]);
        platform_delete_file(path);
        sfree(path);
    }

    char *dir = jsonstore_dir();
    platform_delete_dir(dir);
    sfree(dir);
}
