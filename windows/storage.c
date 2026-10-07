/*
 * storage.c: Windows-specific part of the storage.h implementation.
 *
 * Nothing here touches the Windows registry. The storage format itself
 * (JSON files under %USERPROFILE%\.putty, or $PUTTYDIR) lives in
 * jsonstore.c and is shared with the other platforms; this file
 * provides the filesystem primitives it needs, the Windows-specific
 * setting types (fonts and filenames), and the jump list's
 * recent-sessions list.
 */

#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <assert.h>
#include "putty.h"
#include "storage.h"
#include "jsonstore.h"

#include <shlobj.h>
#ifndef CSIDL_PROFILE
#define CSIDL_PROFILE 0x0028
#endif

/* ----------------------------------------------------------------------
 * Filesystem primitives for jsonstore.c. Paths are UTF-8 on the way
 * in, and converted to UTF-16 so that every legal file name works.
 */

static wchar_t *wpath(const char *path)
{
    wchar_t *w = decode_utf8_to_wide_string(path);
    for (wchar_t *p = w; *p; p++)
        if (*p == L'/')
            *p = L'\\';
    return w;
}

static char *win_error(const char *op, const char *path)
{
    return dupprintf("%s(\"%s\") failed: %s", op, path,
                     win_strerror(GetLastError()));
}

char *platform_getenv_utf8(const char *name)
{
    wchar_t *wname = dup_mb_to_wc(CP_ACP, name);
    const wchar_t *val = _wgetenv(wname);
    sfree(wname);
    return val ? encode_wide_string_as_utf8(val) : NULL;
}

char *platform_default_config_dir(void)
{
    char *home = platform_getenv_utf8("USERPROFILE");
    if (!home || !*home) {
        wchar_t buf[MAX_PATH];
        sfree(home);
        home = NULL;
        if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_PROFILE, NULL, 0, buf)))
            home = encode_wide_string_as_utf8(buf);
    }
    if (!home)
        home = dupstr(".");
    char *dir = dupprintf("%s\\.putty", home);
    sfree(home);
    return dir;
}

char *platform_make_dir(const char *path)
{
    /* Create each component in turn, as CreateDirectory won't. */
    wchar_t *w = wpath(path);
    size_t len = wcslen(w);
    char *err = NULL;

    for (size_t i = 0; i <= len && !err; i++) {
        if (i < len && w[i] != L'\\' && w[i] != L'/')
            continue;
        if (i == 0 || (i == 2 && w[1] == L':'))
            continue;                  /* root or drive letter */
        wchar_t save = w[i];
        w[i] = L'\0';
        DWORD attrs = GetFileAttributesW(w);
        if (attrs == INVALID_FILE_ATTRIBUTES) {
            if (!CreateDirectoryW(w, NULL) &&
                GetLastError() != ERROR_ALREADY_EXISTS)
                err = win_error("CreateDirectory", path);
        } else if (!(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
            err = dupprintf("\"%s\" exists and is not a directory", path);
        }
        w[i] = save;
    }

    sfree(w);
    return err;
}

strbuf *platform_read_file(const char *path)
{
    wchar_t *w = wpath(path);
    HANDLE h = CreateFileW(w, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    sfree(w);
    if (h == INVALID_HANDLE_VALUE)
        return NULL;

    strbuf *sb = strbuf_new_nm();
    while (true) {
        char buf[4096];
        DWORD got;
        if (!ReadFile(h, buf, sizeof(buf), &got, NULL)) {
            strbuf_free(sb);
            sb = NULL;
            break;
        }
        if (got == 0)
            break;
        put_data(sb, buf, got);
    }
    CloseHandle(h);
    return sb;
}

char *platform_write_file(const char *path, const void *data, size_t len)
{
    char *tmppath = dupprintf("%s.tmp.%lu", path,
                              (unsigned long)GetCurrentProcessId());
    wchar_t *wtmp = wpath(tmppath), *wdst = wpath(path);
    char *err = NULL;

    HANDLE h = CreateFileW(wtmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        err = win_error("CreateFile", tmppath);
        goto out;
    }

    const char *p = data;
    while (len > 0 && !err) {
        DWORD chunk = len > 0x10000000 ? 0x10000000 : (DWORD)len, done;
        if (!WriteFile(h, p, chunk, &done, NULL))
            err = win_error("WriteFile", tmppath);
        p += done;
        len -= done;
    }
    if (!err && !FlushFileBuffers(h))
        err = win_error("FlushFileBuffers", tmppath);
    CloseHandle(h);

    if (!err && !MoveFileExW(wtmp, wdst, MOVEFILE_REPLACE_EXISTING |
                             MOVEFILE_WRITE_THROUGH))
        err = win_error("MoveFileEx", path);
    if (err)
        DeleteFileW(wtmp);

  out:
    sfree(wtmp);
    sfree(wdst);
    sfree(tmppath);
    return err;
}

bool platform_delete_file(const char *path)
{
    wchar_t *w = wpath(path);
    bool ok = DeleteFileW(w) || GetLastError() == ERROR_FILE_NOT_FOUND ||
        GetLastError() == ERROR_PATH_NOT_FOUND;
    sfree(w);
    return ok;
}

bool platform_delete_dir(const char *path)
{
    wchar_t *w = wpath(path);
    bool ok = RemoveDirectoryW(w);
    sfree(w);
    return ok;
}

struct platform_dir {
    HANDLE h;
    WIN32_FIND_DATAW fd;
    bool have_entry;
};

platform_dir *platform_open_dir(const char *path)
{
    char *pattern = dupprintf("%s\\*", path);
    wchar_t *w = wpath(pattern);
    sfree(pattern);

    platform_dir *d = snew(platform_dir);
    d->h = FindFirstFileW(w, &d->fd);
    sfree(w);
    if (d->h == INVALID_HANDLE_VALUE) {
        sfree(d);
        return NULL;
    }
    d->have_entry = true;
    return d;
}

char *platform_read_dir(platform_dir *d)
{
    while (d->have_entry) {
        char *name = NULL;
        if (!(d->fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
            name = encode_wide_string_as_utf8(d->fd.cFileName);
        d->have_entry = FindNextFileW(d->h, &d->fd);
        if (name)
            return name;
    }
    return NULL;
}

void platform_close_dir(platform_dir *d)
{
    FindClose(d->h);
    sfree(d);
}

const char *platform_setting_fallback(const char *key)
{
    return NULL;
}

/* ----------------------------------------------------------------------
 * Windows-specific setting types.
 */

FontSpec *read_setting_fontspec(settings_r *handle, const char *name)
{
    char *settingname;
    char *fontname;
    FontSpec *ret;
    int isbold, height, charset;

    fontname = read_setting_s(handle, name);
    if (!fontname)
        return NULL;

    settingname = dupcat(name, "IsBold");
    isbold = read_setting_i(handle, settingname, -1);
    sfree(settingname);
    if (isbold == -1) {
        sfree(fontname);
        return NULL;
    }

    settingname = dupcat(name, "CharSet");
    charset = read_setting_i(handle, settingname, -1);
    sfree(settingname);
    if (charset == -1) {
        sfree(fontname);
        return NULL;
    }

    settingname = dupcat(name, "Height");
    height = read_setting_i(handle, settingname, INT_MIN);
    sfree(settingname);
    if (height == INT_MIN) {
        sfree(fontname);
        return NULL;
    }

    ret = fontspec_new(fontname, isbold, height, charset);
    sfree(fontname);
    return ret;
}

void write_setting_fontspec(settings_w *handle,
                            const char *name, FontSpec *font)
{
    char *settingname;

    write_setting_s(handle, name, font->name);
    settingname = dupcat(name, "IsBold");
    write_setting_i(handle, settingname, font->isbold);
    sfree(settingname);
    settingname = dupcat(name, "CharSet");
    write_setting_i(handle, settingname, font->charset);
    sfree(settingname);
    settingname = dupcat(name, "Height");
    write_setting_i(handle, settingname, font->height);
    sfree(settingname);
}

Filename *read_setting_filename(settings_r *handle, const char *name)
{
    char *tmp = read_setting_s(handle, name);
    if (tmp) {
        Filename *ret = filename_from_utf8(tmp);
        sfree(tmp);
        return ret;
    } else
        return NULL;
}

void write_setting_filename(settings_w *handle,
                            const char *name, Filename *result)
{
    /*
     * The JSON files are UTF-8 throughout, so (unlike the registry
     * format this replaces) we can store any filename faithfully.
     */
    write_setting_s(handle, name, result->utf8path);
}

/* ----------------------------------------------------------------------
 * Recent sessions for the jump list, kept in jumplist.json:
 *
 *   { "format": "putty-jumplist", "version": 1, "recent": [ ... ] }
 */

#define JUMPLIST_FILE "jumplist.json"

/*
 * Adjust the recent-sessions list by adding 'add' to the front (if
 * non-null) and removing 'rem' (if non-null), and return the result
 * as a sequence of NUL-terminated strings ending with an empty one
 * in 'out' (if non-null). Sessions that no longer exist are dropped.
 */
static int transform_jumplist(const char *add, const char *rem, char **out)
{
    JsonValue *doc = jsonstore_load(JUMPLIST_FILE, NULL);
    JsonValue *old = doc ? json_object_get(doc, "recent") : NULL;
    strbuf *list = strbuf_new();
    int ret = JUMPLISTREG_OK;

    if (add || rem) {
        JsonValue *newdoc = json_new_object();
        JsonValue *recent = json_new_array();
        json_object_set(newdoc, "format", json_new_string("putty-jumplist"));
        json_object_set(newdoc, "version", json_new_int(1));

        if (add) {
            json_array_append(recent, json_new_string(add));
            put_asciz(list, add);
        }
        for (size_t i = 0; i < json_array_len(old); i++) {
            const char *item = json_get_string(json_array_get(old, i));
            if (!item || (rem && !strcmp(item, rem)))
                continue;
            /* Check if this is a valid session, otherwise don't add. */
            settings_r *sr = open_settings_r(item);
            if (!sr)
                continue;
            close_settings_r(sr);
            json_array_append(recent, json_new_string(item));
            put_asciz(list, item);
        }
        json_object_set(newdoc, "recent", recent);

        char *err = jsonstore_save(JUMPLIST_FILE, newdoc);
        if (err) {
            ret = JUMPLISTREG_ERROR_VALUEWRITE_FAILURE;
            sfree(err);
        }
        json_free(newdoc);
    } else {
        for (size_t i = 0; i < json_array_len(old); i++) {
            const char *item = json_get_string(json_array_get(old, i));
            if (item)
                put_asciz(list, item);
        }
    }
    put_byte(list, '\0');

    json_free(doc);
    if (out && ret == JUMPLISTREG_OK)
        *out = strbuf_to_str(list);
    else
        strbuf_free(list);
    return ret;
}

/* Adds a new entry to the recent-sessions list. */
int add_to_jumplist_registry(const char *item)
{
    return transform_jumplist(item, item, NULL);
}

/* Removes an item from the recent-sessions list. */
int remove_from_jumplist_registry(const char *item)
{
    return transform_jumplist(NULL, item, NULL);
}

/* Returns the recent-sessions list. Caller must free the returned
 * pointer. */
char *get_jumplist_registry_entries(void)
{
    char *list_value;

    if (transform_jumplist(NULL, NULL, &list_value) != JUMPLISTREG_OK) {
        list_value = snewn(2, char);
        *list_value = '\0';
        *(list_value + 1) = '\0';
    }
    return list_value;
}

void cleanup_all(void)
{
    /* Ask Windows to delete any jump list information associated
     * with this installation of PuTTY. */
    clear_jumplist();

    /* Then remove every file we store. */
    jsonstore_cleanup_all();
}
