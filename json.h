/*
 * json.h: a small JSON reader and writer, used for PuTTY's
 * file-based configuration storage.
 *
 * This is deliberately minimal. It supports the full JSON grammar
 * for parsing, but numbers are only exposed to callers as integers
 * (which is all the storage layer needs), and strings may not contain
 * embedded NUL characters (since they are handed out as C strings).
 */

#ifndef PUTTY_JSON_H
#define PUTTY_JSON_H

#include "defs.h"

typedef struct JsonValue JsonValue;

typedef enum JsonType {
    JSON_NULL, JSON_BOOL, JSON_NUMBER, JSON_STRING, JSON_ARRAY, JSON_OBJECT
} JsonType;

/*
 * Parse a complete JSON document. On failure, returns NULL and (if
 * err is not NULL) sets *err to a dynamically allocated message.
 */
JsonValue *json_parse(ptrlen text, char **err);

/* Serialise a value, pretty-printed with two-space indentation. */
void json_write(const JsonValue *v, strbuf *out);

void json_free(JsonValue *v);

JsonValue *json_new_null(void);
JsonValue *json_new_bool(bool b);
JsonValue *json_new_int(long long n);
JsonValue *json_new_string(const char *s);
JsonValue *json_new_array(void);
JsonValue *json_new_object(void);

JsonType json_type(const JsonValue *v);

/* Accessors. These return false / NULL if the value has the wrong type. */
bool json_get_bool(const JsonValue *v, bool *out);
bool json_get_int(const JsonValue *v, long long *out);
const char *json_get_string(const JsonValue *v);

size_t json_array_len(const JsonValue *arr);
JsonValue *json_array_get(const JsonValue *arr, size_t i);
/* Takes ownership of val. */
void json_array_append(JsonValue *arr, JsonValue *val);

size_t json_object_len(const JsonValue *obj);
const char *json_object_key(const JsonValue *obj, size_t i);
JsonValue *json_object_value(const JsonValue *obj, size_t i);
JsonValue *json_object_get(const JsonValue *obj, const char *key);
/* Takes ownership of val, replacing (and freeing) any existing value. */
void json_object_set(JsonValue *obj, const char *key, JsonValue *val);
/* Returns true if the key was present. */
bool json_object_delete(JsonValue *obj, const char *key);

#endif
