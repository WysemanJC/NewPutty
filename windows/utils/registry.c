/*
 * Implement convenience wrappers on the awkward low-level functions
 * for accessing the Windows registry.
 *
 * This build of PuTTY never writes to the registry (all its own data
 * lives in JSON files; see jsonstore.c), so only read access is
 * provided here. It is still needed to find other software's
 * installation details (e.g. MIT Kerberos, the help file).
 */

#include "putty.h"

HKEY open_regkey_fn(HKEY hk, const char *path, ...)
{
    HKEY toret = NULL;
    bool hk_needs_close = false;
    va_list ap;
    va_start(ap, path);

    for (; path; path = va_arg(ap, const char *)) {
        HKEY hk_sub = NULL;

        LONG status = RegOpenKeyEx(hk, path, 0, KEY_READ, &hk_sub);

        if (status != ERROR_SUCCESS)
            goto out;

        if (hk_needs_close)
            RegCloseKey(hk);
        hk = hk_sub;
        hk_needs_close = true;
    }

    toret = hk;
    hk = NULL;
    hk_needs_close = false;

  out:
    va_end(ap);
    if (hk_needs_close)
        RegCloseKey(hk);
    return toret;
}

void close_regkey(HKEY key)
{
    RegCloseKey(key);
}

char *enum_regkey(HKEY key, int index)
{
    size_t regbuf_size = MAX_PATH + 1;
    char *regbuf = snewn(regbuf_size, char);

    while (1) {
        LONG status = RegEnumKey(key, index, regbuf, regbuf_size);
        if (status == ERROR_SUCCESS)
            return regbuf;
        if (status != ERROR_MORE_DATA) {
            sfree(regbuf);
            return NULL;
        }
        sgrowarray(regbuf, regbuf_size, regbuf_size);
    }
}

bool get_reg_dword(HKEY key, const char *name, DWORD *out)
{
    DWORD type, size;
    size = sizeof(*out);

    if (RegQueryValueEx(key, name, 0, &type,
                        (BYTE *)out, &size) != ERROR_SUCCESS ||
        size != sizeof(*out) || type != REG_DWORD)
        return false;
    else
        return true;
}

char *get_reg_sz(HKEY key, const char *name)
{
    DWORD type, size;

    if (RegQueryValueEx(key, name, 0, &type, NULL,
                        &size) != ERROR_SUCCESS || type != REG_SZ)
        return NULL;                   /* not a string */

    size_t allocsize = size+1;         /* allow for an extra NUL if needed */
    char *toret = snewn(allocsize, char);
    if (RegQueryValueEx(key, name, 0, &type, (BYTE *)toret,
                        &size) != ERROR_SUCCESS || type != REG_SZ) {
        sfree(toret);
        return NULL;
    }
    assert(size < allocsize);
    toret[size] = '\0'; /* add an extra NUL in case RegQueryValueEx
                         * didn't supply one */

    return toret;
}

/*
 * REG_MULTI_SZ items are stored as a concatenation of NUL-terminated
 * strings, terminated in turn with an empty string, i.e. a second
 * consecutive NUL.
 *
 * We represent these in their storage format, as a strbuf - but
 * *without* the second consecutive NUL.
 *
 * You can consume one by initialising a BinarySource to the result of
 * get_reg_multi_sz, and then calling get_asciz on it and assuming
 * that !get_err(src) means you have a real output string.
 *
 * Also, calling strbuf_to_str on one of these will give you back a
 * bare 'char *' with the same double-NUL termination, to pass back to
 * a caller.
 */
strbuf *get_reg_multi_sz(HKEY key, const char *name)
{
    DWORD type, size;

    if (RegQueryValueEx(key, name, 0, &type, NULL,
                        &size) != ERROR_SUCCESS || type != REG_MULTI_SZ)
        return NULL;                   /* not a string */

    strbuf *toret = strbuf_new();
    void *ptr = strbuf_append(toret, (size_t)size + 2);
    if (RegQueryValueEx(key, name, 0, &type, (BYTE *)ptr,
                        &size) != ERROR_SUCCESS || type != REG_MULTI_SZ) {
        strbuf_free(toret);
        return NULL;
    }
    strbuf_shrink_to(toret, size);
    /* Ensure we end with exactly one \0 */
    while (strbuf_chomp(toret, '\0'));
    put_byte(toret, '\0');
    return toret;
}

char *get_reg_sz_simple(HKEY key, const char *name, const char *leaf)
{
    HKEY subkey = open_regkey_ro(key, name);
    if (!subkey)
        return NULL;
    char *toret = get_reg_sz(subkey, leaf);
    RegCloseKey(subkey);
    return toret;
}
