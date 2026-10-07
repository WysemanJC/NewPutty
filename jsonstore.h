/*
 * jsonstore.h: internal interface between the platform-independent
 * JSON implementation of storage.h (jsonstore.c) and the small set of
 * filesystem primitives each platform provides.
 *
 * All paths passed across this interface are UTF-8.
 *
 * On-disk layout, under the configuration directory (which is
 * $PUTTYDIR if set, otherwise ".putty" in the user's home directory):
 *
 *   sessions/<encoded name>.json   one file per saved session
 *   hostcas/<encoded name>.json    one file per trusted host CA
 *   hostkeys.json                  the SSH host key cache
 *   randomseed                     random seed (binary, not JSON)
 *   jumplist.json                  Windows jump list (recent sessions)
 */

#ifndef PUTTY_JSONSTORE_H
#define PUTTY_JSONSTORE_H

#include "json.h"

/* Name of the environment variable overriding the config directory. */
#define JSONSTORE_DIR_ENV "PUTTYDIR"

/* ----------------------------------------------------------------------
 * Provided by jsonstore.c for platform code.
 */

/* The configuration directory (dynamically allocated). */
char *jsonstore_dir(void);

/* Full path of a file within the configuration directory. */
char *jsonstore_path(const char *leaf);

/*
 * Load a JSON file from the configuration directory. Returns NULL if
 * the file doesn't exist or can't be parsed; in the latter case *err
 * (if err is non-NULL) is set to an error message.
 */
JsonValue *jsonstore_load(const char *leaf, char **err);

/*
 * Atomically write a JSON value to a file in the configuration
 * directory, creating the directory if necessary. Returns NULL on
 * success, or a dynamically allocated error message.
 */
char *jsonstore_save(const char *leaf, const JsonValue *v);

/* Remove every file this module manages (used by cleanup_all). */
void jsonstore_cleanup_all(void);

/* ----------------------------------------------------------------------
 * Provided by each platform's storage.c.
 */

/* The default configuration directory, i.e. <home>/.putty. */
char *platform_default_config_dir(void);

/* getenv(), returning a UTF-8 copy or NULL. */
char *platform_getenv_utf8(const char *name);

/* Create a directory and any missing parents, private to the user.
 * Returns NULL on success, or a dynamically allocated error message. */
char *platform_make_dir(const char *path);

/* Read a whole file. Returns NULL if it can't be read. */
strbuf *platform_read_file(const char *path);

/*
 * Write a whole file atomically (write to a temporary file in the
 * same directory, flush it, then rename it over the target), with
 * permissions restricting it to the current user. Returns NULL on
 * success, or a dynamically allocated error message.
 */
char *platform_write_file(const char *path, const void *data, size_t len);

/* Remove a file. Returns true if it was removed or didn't exist. */
bool platform_delete_file(const char *path);

/* Remove an (empty) directory. */
bool platform_delete_dir(const char *path);

/* Directory enumeration: returns leaf names, or NULL at the end. */
typedef struct platform_dir platform_dir;
platform_dir *platform_open_dir(const char *path);
char *platform_read_dir(platform_dir *d);
void platform_close_dir(platform_dir *d);

/*
 * Fallback source of session settings not present in the loaded
 * file (X resources on Unix). May return NULL.
 */
const char *platform_setting_fallback(const char *key);

#endif
