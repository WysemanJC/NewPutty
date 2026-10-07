/*
 * storage.c: Unix-specific part of the storage.h implementation.
 *
 * The storage format itself (JSON files under ~/.putty) lives in
 * jsonstore.c and is shared with Windows; this file provides the
 * filesystem primitives it needs, plus the Unix-specific parts of
 * the interface (font and filename settings, and X resources as a
 * fallback source of defaults).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <errno.h>
#include <ctype.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <pwd.h>
#include "putty.h"
#include "storage.h"
#include "tree234.h"
#include "jsonstore.h"

/* ----------------------------------------------------------------------
 * Filesystem primitives for jsonstore.c.
 */

char *platform_getenv_utf8(const char *name)
{
    const char *val = getenv(name);
    return val ? dupstr(val) : NULL;
}

char *platform_default_config_dir(void)
{
    const char *home = getenv("HOME");
    if (!home || !*home) {
        struct passwd *pwd = getpwuid(getuid());
        home = (pwd && pwd->pw_dir) ? pwd->pw_dir : "";
    }
    return dupprintf("%s/.putty", home);
}

char *platform_make_dir(const char *path)
{
    return make_dir_path(path, 0700);
}

strbuf *platform_read_file(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return NULL;

    strbuf *sb = strbuf_new_nm();
    while (true) {
        char buf[4096];
        ssize_t ret = read(fd, buf, sizeof(buf));
        if (ret < 0) {
            if (errno == EINTR)
                continue;
            strbuf_free(sb);
            sb = NULL;
            break;
        }
        if (ret == 0)
            break;
        put_data(sb, buf, ret);
    }
    close(fd);
    return sb;
}

char *platform_write_file(const char *path, const void *data, size_t len)
{
    char *tmppath = dupprintf("%s.tmp.%lu", path, (unsigned long)getpid());
    char *err = NULL;

    int fd = open(tmppath, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd < 0 && errno == EEXIST) {
        /* Stale temporary file from a crashed process with our pid. */
        unlink(tmppath);
        fd = open(tmppath, O_CREAT | O_EXCL | O_WRONLY, 0600);
    }
    if (fd < 0) {
        err = dupprintf("open(\"%s\") returned '%s'",
                        tmppath, strerror(errno));
        sfree(tmppath);
        return err;
    }

    const char *p = data;
    while (len > 0) {
        ssize_t ret = write(fd, p, len);
        if (ret < 0) {
            if (errno == EINTR)
                continue;
            err = dupprintf("write(\"%s\") returned '%s'",
                            tmppath, strerror(errno));
            break;
        }
        p += ret;
        len -= ret;
    }

    if (!err && fsync(fd) < 0)
        err = dupprintf("fsync(\"%s\") returned '%s'",
                        tmppath, strerror(errno));
    if (close(fd) < 0 && !err)
        err = dupprintf("close(\"%s\") returned '%s'",
                        tmppath, strerror(errno));
    if (!err && rename(tmppath, path) < 0)
        err = dupprintf("rename(\"%s\", \"%s\") returned '%s'",
                        tmppath, path, strerror(errno));
    if (err)
        unlink(tmppath);

    sfree(tmppath);
    return err;
}

bool platform_delete_file(const char *path)
{
    return unlink(path) == 0 || errno == ENOENT;
}

bool platform_delete_dir(const char *path)
{
    return rmdir(path) == 0;
}

struct platform_dir {
    DIR *dp;
    char *path;
};

platform_dir *platform_open_dir(const char *path)
{
    DIR *dp = opendir(path);
    if (!dp)
        return NULL;
    platform_dir *d = snew(platform_dir);
    d->dp = dp;
    d->path = dupstr(path);
    return d;
}

char *platform_read_dir(platform_dir *d)
{
    struct dirent *de;
    while ((de = readdir(d->dp)) != NULL) {
        /* Only regular files (following symlinks) are of interest. */
        char *full = dupprintf("%s/%s", d->path, de->d_name);
        struct stat st;
        bool ok = stat(full, &st) == 0 && S_ISREG(st.st_mode);
        sfree(full);
        if (ok)
            return dupstr(de->d_name);
    }
    return NULL;
}

void platform_close_dir(platform_dir *d)
{
    closedir(d->dp);
    sfree(d->path);
    sfree(d);
}

/* ----------------------------------------------------------------------
 * System for treating X resources as a fallback source of defaults,
 * after data read from a saved-session file.
 *
 * read_setting_* in jsonstore.c call platform_setting_fallback(key)
 * if the setting isn't in the file they loaded. That in turn will hand
 * on to x_get_default, which the front end application provides, and
 * which actually reads resources from the X server (if appropriate).
 * In between, there's a tree234 of X-resource shaped settings living
 * locally in this file: the front end can call provide_xrm_string()
 * to insert a setting into this tree (typically in response to an
 * -xrm command line option or similar), and those will override the
 * actual X resources.
 */

struct skeyval {
    const char *key;
    const char *value;
};

static tree234 *xrmtree = NULL;

static int keycmp(void *av, void *bv)
{
    struct skeyval *a = (struct skeyval *)av;
    struct skeyval *b = (struct skeyval *)bv;
    return strcmp(a->key, b->key);
}

void provide_xrm_string(const char *string, const char *progname)
{
    const char *p, *q;
    struct skeyval *xrms, *ret;

    p = q = strchr(string, ':');
    if (!q) {
        fprintf(stderr, "%s: expected a colon in resource string"
                " \"%s\"\n", progname, string);
        return;
    }
    xrms = snew(struct skeyval);

    while (p > string && p[-1] != '.' && p[-1] != '*')
        p--;
    xrms->key = mkstr(make_ptrlen(p, q-p));

    q++;
    while (*q && isspace((unsigned char)*q))
        q++;
    xrms->value = dupstr(q);

    if (!xrmtree)
        xrmtree = newtree234(keycmp);

    ret = add234(xrmtree, xrms);
    if (ret) {
        /* Override an existing string. */
        del234(xrmtree, ret);
        add234(xrmtree, xrms);
    }
}

const char *platform_setting_fallback(const char *key)
{
    struct skeyval tmp, *ret;
    tmp.key = key;
    if (xrmtree) {
        ret = find234(xrmtree, &tmp, NULL);
        if (ret)
            return ret->value;
    }
    return x_get_default(key);
}

/* ----------------------------------------------------------------------
 * Unix-specific setting types.
 */

FontSpec *read_setting_fontspec(settings_r *handle, const char *name)
{
    /*
     * In GTK1-only PuTTY, we used to store font names simply as a
     * valid X font description string (logical or alias), under a
     * bare key such as "Font".
     *
     * In GTK2 PuTTY, we have a prefix system where "client:"
     * indicates a Pango font and "server:" an X one; existing
     * configuration needs to be reinterpreted as having the
     * "server:" prefix, so we change the storage key from the
     * provided name string (e.g. "Font") to a suffixed one
     * ("FontName").
     */
    char *suffname = dupcat(name, "Name");
    char *tmp;

    if ((tmp = read_setting_s(handle, suffname)) != NULL) {
        FontSpec *fs = fontspec_new(tmp);
        sfree(suffname);
        sfree(tmp);
        return fs;                     /* got new-style name */
    }
    sfree(suffname);

    /* Fall back to old-style name. */
    tmp = read_setting_s(handle, name);
    if (tmp && *tmp) {
        char *tmp2 = dupcat("server:", tmp);
        FontSpec *fs = fontspec_new(tmp2);
        sfree(tmp2);
        sfree(tmp);
        return fs;
    } else {
        sfree(tmp);
        return NULL;
    }
}

Filename *read_setting_filename(settings_r *handle, const char *name)
{
    char *tmp = read_setting_s(handle, name);
    if (tmp) {
        Filename *ret = filename_from_str(tmp);
        sfree(tmp);
        return ret;
    } else
        return NULL;
}

void write_setting_fontspec(settings_w *handle, const char *name, FontSpec *fs)
{
    /*
     * read_setting_fontspec had to handle two cases, but when
     * writing our settings back out we simply always generate the
     * new-style name.
     */
    char *suffname = dupcat(name, "Name");
    write_setting_s(handle, suffname, fs->name);
    sfree(suffname);
}

void write_setting_filename(settings_w *handle,
                            const char *name, Filename *result)
{
    write_setting_s(handle, name, result->path);
}

void cleanup_all(void)
{
    jsonstore_cleanup_all();
}
