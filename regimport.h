/*
 * regimport.h: importing upstream PuTTY's Windows registry settings
 * (a .reg export) into this fork's JSON store.
 */

#ifndef PUTTY_REGIMPORT_H
#define PUTTY_REGIMPORT_H

#include "defs.h"

/* The registry key whose contents are imported; everything else in
 * the file is ignored. */
#define REGIMPORT_ROOT "HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY"

typedef struct RegImportResult {
    bool ok;                 /* false if the file couldn't be used at all */
    size_t sessions_added, sessions_existing;
    size_t hostkeys_added, hostkeys_existing;
    size_t cas_added, cas_existing;
    size_t ignored;          /* values of types we don't import, etc. */
    strbuf *errors;          /* one line per problem; may be empty */
} RegImportResult;

/*
 * Import saved sessions (Sessions\*), SSH host keys (SshHostKeys) and
 * trusted host CAs (SshHostCAs\*) from the text of a .reg export
 * (UTF-16 as written by regedit, or REGEDIT4/UTF-8). Anything that
 * already exists in the JSON store is left alone, never overwritten.
 */
void regimport_data(ptrlen data, RegImportResult *res);

/* As regimport_data, reading the file first. */
void regimport_file(const Filename *fn, RegImportResult *res);

/* A human-readable summary of a result, for a message box. */
char *regimport_describe(const RegImportResult *res);

void regimport_result_free(RegImportResult *res);

#endif
