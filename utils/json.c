/*
 * json.c: a small JSON reader and writer. See json.h.
 */

#include <assert.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "putty.h"
#include "json.h"

/* Limit nesting so that malformed input can't exhaust the stack. */
#define JSON_MAX_DEPTH 64

struct JsonMember {
    char *key;
    JsonValue *value;
};

struct JsonValue {
    JsonType type;
    union {
        bool b;
        long long n;
        char *s;
        struct {
            JsonValue **items;
            size_t len, size;
        } arr;
        struct {
            struct JsonMember *members;
            size_t len, size;
        } obj;
    } u;
};

static JsonValue *json_new(JsonType type)
{
    JsonValue *v = snew(JsonValue);
    memset(v, 0, sizeof(*v));
    v->type = type;
    return v;
}

JsonValue *json_new_null(void) { return json_new(JSON_NULL); }

JsonValue *json_new_bool(bool b)
{
    JsonValue *v = json_new(JSON_BOOL);
    v->u.b = b;
    return v;
}

JsonValue *json_new_int(long long n)
{
    JsonValue *v = json_new(JSON_NUMBER);
    v->u.n = n;
    return v;
}

JsonValue *json_new_string(const char *s)
{
    JsonValue *v = json_new(JSON_STRING);
    v->u.s = dupstr(s);
    return v;
}

JsonValue *json_new_array(void) { return json_new(JSON_ARRAY); }
JsonValue *json_new_object(void) { return json_new(JSON_OBJECT); }

void json_free(JsonValue *v)
{
    if (!v)
        return;
    switch (v->type) {
      case JSON_STRING:
        sfree(v->u.s);
        break;
      case JSON_ARRAY:
        for (size_t i = 0; i < v->u.arr.len; i++)
            json_free(v->u.arr.items[i]);
        sfree(v->u.arr.items);
        break;
      case JSON_OBJECT:
        for (size_t i = 0; i < v->u.obj.len; i++) {
            sfree(v->u.obj.members[i].key);
            json_free(v->u.obj.members[i].value);
        }
        sfree(v->u.obj.members);
        break;
      default:
        break;
    }
    sfree(v);
}

JsonType json_type(const JsonValue *v) { return v->type; }

bool json_get_bool(const JsonValue *v, bool *out)
{
    if (!v || v->type != JSON_BOOL)
        return false;
    *out = v->u.b;
    return true;
}

bool json_get_int(const JsonValue *v, long long *out)
{
    if (!v || v->type != JSON_NUMBER)
        return false;
    *out = v->u.n;
    return true;
}

const char *json_get_string(const JsonValue *v)
{
    if (!v || v->type != JSON_STRING)
        return NULL;
    return v->u.s;
}

size_t json_array_len(const JsonValue *arr)
{
    return (arr && arr->type == JSON_ARRAY) ? arr->u.arr.len : 0;
}

JsonValue *json_array_get(const JsonValue *arr, size_t i)
{
    if (!arr || arr->type != JSON_ARRAY || i >= arr->u.arr.len)
        return NULL;
    return arr->u.arr.items[i];
}

void json_array_append(JsonValue *arr, JsonValue *val)
{
    assert(arr->type == JSON_ARRAY);
    sgrowarray(arr->u.arr.items, arr->u.arr.size, arr->u.arr.len);
    arr->u.arr.items[arr->u.arr.len++] = val;
}

size_t json_object_len(const JsonValue *obj)
{
    return (obj && obj->type == JSON_OBJECT) ? obj->u.obj.len : 0;
}

const char *json_object_key(const JsonValue *obj, size_t i)
{
    if (!obj || obj->type != JSON_OBJECT || i >= obj->u.obj.len)
        return NULL;
    return obj->u.obj.members[i].key;
}

JsonValue *json_object_value(const JsonValue *obj, size_t i)
{
    if (!obj || obj->type != JSON_OBJECT || i >= obj->u.obj.len)
        return NULL;
    return obj->u.obj.members[i].value;
}

static struct JsonMember *json_object_find(const JsonValue *obj,
                                           const char *key)
{
    if (!obj || obj->type != JSON_OBJECT)
        return NULL;
    for (size_t i = 0; i < obj->u.obj.len; i++)
        if (!strcmp(obj->u.obj.members[i].key, key))
            return &obj->u.obj.members[i];
    return NULL;
}

JsonValue *json_object_get(const JsonValue *obj, const char *key)
{
    struct JsonMember *m = json_object_find(obj, key);
    return m ? m->value : NULL;
}

void json_object_set(JsonValue *obj, const char *key, JsonValue *val)
{
    assert(obj->type == JSON_OBJECT);
    struct JsonMember *m = json_object_find(obj, key);
    if (m) {
        json_free(m->value);
        m->value = val;
        return;
    }
    sgrowarray(obj->u.obj.members, obj->u.obj.size, obj->u.obj.len);
    m = &obj->u.obj.members[obj->u.obj.len++];
    m->key = dupstr(key);
    m->value = val;
}

bool json_object_delete(JsonValue *obj, const char *key)
{
    struct JsonMember *m = json_object_find(obj, key);
    if (!m)
        return false;
    size_t i = m - obj->u.obj.members;
    sfree(m->key);
    json_free(m->value);
    memmove(&obj->u.obj.members[i], &obj->u.obj.members[i+1],
            (obj->u.obj.len - i - 1) * sizeof(struct JsonMember));
    obj->u.obj.len--;
    return true;
}

/* ----------------------------------------------------------------------
 * Parser.
 */

typedef struct JsonParser {
    const char *p, *end;
    char *err;
    int depth;
} JsonParser;

static void jp_error(JsonParser *jp, const char *msg)
{
    if (!jp->err)
        jp->err = dupstr(msg);
}

static void jp_skip_ws(JsonParser *jp)
{
    while (jp->p < jp->end &&
           (*jp->p == ' ' || *jp->p == '\t' ||
            *jp->p == '\n' || *jp->p == '\r'))
        jp->p++;
}

static bool jp_literal(JsonParser *jp, const char *lit)
{
    size_t len = strlen(lit);
    if ((size_t)(jp->end - jp->p) >= len && !memcmp(jp->p, lit, len)) {
        jp->p += len;
        return true;
    }
    return false;
}

static int jp_hex4(JsonParser *jp)
{
    int val = 0;
    if (jp->end - jp->p < 4)
        return -1;
    for (int i = 0; i < 4; i++) {
        char c = *jp->p++;
        val <<= 4;
        if (c >= '0' && c <= '9')
            val |= c - '0';
        else if (c >= 'a' && c <= 'f')
            val |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            val |= c - 'A' + 10;
        else
            return -1;
    }
    return val;
}

static char *jp_string(JsonParser *jp)
{
    assert(jp->p < jp->end && *jp->p == '"');
    jp->p++;

    strbuf *sb = strbuf_new();
    while (true) {
        if (jp->p >= jp->end) {
            jp_error(jp, "unterminated string");
            break;
        }
        unsigned char c = *jp->p++;
        if (c == '"')
            return strbuf_to_str(sb);
        if (c < 0x20) {
            jp_error(jp, "control character in string");
            break;
        }
        if (c != '\\') {
            put_byte(sb, c);
            continue;
        }
        if (jp->p >= jp->end) {
            jp_error(jp, "unterminated string");
            break;
        }
        c = *jp->p++;
        switch (c) {
          case '"': put_byte(sb, '"'); break;
          case '\\': put_byte(sb, '\\'); break;
          case '/': put_byte(sb, '/'); break;
          case 'b': put_byte(sb, '\b'); break;
          case 'f': put_byte(sb, '\f'); break;
          case 'n': put_byte(sb, '\n'); break;
          case 'r': put_byte(sb, '\r'); break;
          case 't': put_byte(sb, '\t'); break;
          case 'u': {
            int cp = jp_hex4(jp);
            if (cp < 0) {
                jp_error(jp, "bad \\u escape");
                goto fail;
            }
            if (cp >= 0xD800 && cp < 0xDC00) {
                int lo;
                if (!jp_literal(jp, "\\u") || (lo = jp_hex4(jp)) < 0 ||
                    lo < 0xDC00 || lo >= 0xE000) {
                    jp_error(jp, "unpaired surrogate in \\u escape");
                    goto fail;
                }
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else if (cp >= 0xDC00 && cp < 0xE000) {
                jp_error(jp, "unpaired surrogate in \\u escape");
                goto fail;
            }
            if (cp == 0) {
                jp_error(jp, "NUL character in string");
                goto fail;
            }
            put_utf8_char(sb, cp);
            break;
          }
          default:
            jp_error(jp, "bad escape in string");
            goto fail;
        }
    }
  fail:
    strbuf_free(sb);
    return NULL;
}

static JsonValue *jp_value(JsonParser *jp);

static JsonValue *jp_number(JsonParser *jp)
{
    bool neg = false;
    unsigned long long mag = 0;
    bool overflow = false;

    if (*jp->p == '-') {
        neg = true;
        jp->p++;
    }
    if (jp->p >= jp->end || *jp->p < '0' || *jp->p > '9') {
        jp_error(jp, "bad number");
        return NULL;
    }
    if (*jp->p == '0' && jp->p + 1 < jp->end &&
        jp->p[1] >= '0' && jp->p[1] <= '9') {
        jp_error(jp, "leading zero in number");
        return NULL;
    }
    while (jp->p < jp->end && *jp->p >= '0' && *jp->p <= '9') {
        unsigned digit = *jp->p++ - '0';
        if (mag > (ULLONG_MAX - digit) / 10)
            overflow = true;
        else
            mag = mag * 10 + digit;
    }
    if (jp->p < jp->end &&
        (*jp->p == '.' || *jp->p == 'e' || *jp->p == 'E')) {
        /* Valid JSON, but nothing in our storage format uses it. */
        jp_error(jp, "non-integer numbers are not supported");
        return NULL;
    }
    if (overflow || mag > (unsigned long long)LLONG_MAX + (neg ? 1 : 0)) {
        jp_error(jp, "number out of range");
        return NULL;
    }
    return json_new_int(neg ? (long long)(0 - mag) : (long long)mag);
}

static JsonValue *jp_array(JsonParser *jp)
{
    jp->p++;                           /* skip '[' */
    JsonValue *arr = json_new_array();
    jp_skip_ws(jp);
    if (jp->p < jp->end && *jp->p == ']') {
        jp->p++;
        return arr;
    }
    while (true) {
        JsonValue *item = jp_value(jp);
        if (!item)
            goto fail;
        json_array_append(arr, item);
        jp_skip_ws(jp);
        if (jp->p < jp->end && *jp->p == ',') {
            jp->p++;
            continue;
        }
        if (jp->p < jp->end && *jp->p == ']') {
            jp->p++;
            return arr;
        }
        jp_error(jp, "expected ',' or ']' in array");
        goto fail;
    }
  fail:
    json_free(arr);
    return NULL;
}

static JsonValue *jp_object(JsonParser *jp)
{
    jp->p++;                           /* skip '{' */
    JsonValue *obj = json_new_object();
    jp_skip_ws(jp);
    if (jp->p < jp->end && *jp->p == '}') {
        jp->p++;
        return obj;
    }
    while (true) {
        jp_skip_ws(jp);
        if (jp->p >= jp->end || *jp->p != '"') {
            jp_error(jp, "expected string key in object");
            goto fail;
        }
        char *key = jp_string(jp);
        if (!key)
            goto fail;
        jp_skip_ws(jp);
        if (jp->p >= jp->end || *jp->p != ':') {
            sfree(key);
            jp_error(jp, "expected ':' in object");
            goto fail;
        }
        jp->p++;
        JsonValue *val = jp_value(jp);
        if (!val) {
            sfree(key);
            goto fail;
        }
        /* Duplicate keys: the last one wins, as in most parsers. */
        json_object_set(obj, key, val);
        sfree(key);
        jp_skip_ws(jp);
        if (jp->p < jp->end && *jp->p == ',') {
            jp->p++;
            continue;
        }
        if (jp->p < jp->end && *jp->p == '}') {
            jp->p++;
            return obj;
        }
        jp_error(jp, "expected ',' or '}' in object");
        goto fail;
    }
  fail:
    json_free(obj);
    return NULL;
}

static JsonValue *jp_value(JsonParser *jp)
{
    JsonValue *v = NULL;

    jp_skip_ws(jp);
    if (jp->p >= jp->end) {
        jp_error(jp, "unexpected end of input");
        return NULL;
    }
    if (++jp->depth > JSON_MAX_DEPTH) {
        jp_error(jp, "nesting too deep");
        return NULL;
    }

    switch (*jp->p) {
      case '{':
        v = jp_object(jp);
        break;
      case '[':
        v = jp_array(jp);
        break;
      case '"': {
        char *s = jp_string(jp);
        if (s) {
            v = json_new(JSON_STRING);
            v->u.s = s;
        }
        break;
      }
      case 't':
        if (jp_literal(jp, "true"))
            v = json_new_bool(true);
        else
            jp_error(jp, "unexpected token");
        break;
      case 'f':
        if (jp_literal(jp, "false"))
            v = json_new_bool(false);
        else
            jp_error(jp, "unexpected token");
        break;
      case 'n':
        if (jp_literal(jp, "null"))
            v = json_new_null();
        else
            jp_error(jp, "unexpected token");
        break;
      default:
        if (*jp->p == '-' || (*jp->p >= '0' && *jp->p <= '9'))
            v = jp_number(jp);
        else
            jp_error(jp, "unexpected character");
        break;
    }

    jp->depth--;
    return v;
}

JsonValue *json_parse(ptrlen text, char **err)
{
    JsonParser jp[1];
    jp->p = text.ptr;
    jp->end = jp->p + text.len;
    jp->err = NULL;
    jp->depth = 0;

    /* Tolerate a UTF-8 byte order mark, as Windows editors add one. */
    if (jp->end - jp->p >= 3 && !memcmp(jp->p, "\xEF\xBB\xBF", 3))
        jp->p += 3;

    JsonValue *v = jp_value(jp);
    if (v) {
        jp_skip_ws(jp);
        if (jp->p != jp->end) {
            jp_error(jp, "trailing data after JSON value");
            json_free(v);
            v = NULL;
        }
    }

    if (!v) {
        if (err)
            *err = dupprintf("JSON parse error at offset %d: %s",
                             (int)(jp->p - (const char *)text.ptr),
                             jp->err ? jp->err : "unknown error");
    }
    sfree(jp->err);
    return v;
}

/* ----------------------------------------------------------------------
 * Writer.
 */

static void jw_indent(strbuf *out, int depth)
{
    for (int i = 0; i < depth; i++)
        put_datapl(out, PTRLEN_LITERAL("  "));
}

static void jw_string(strbuf *out, const char *s)
{
    put_byte(out, '"');
    for (; *s; s++) {
        unsigned char c = *s;
        switch (c) {
          case '"': put_datapl(out, PTRLEN_LITERAL("\\\"")); break;
          case '\\': put_datapl(out, PTRLEN_LITERAL("\\\\")); break;
          case '\n': put_datapl(out, PTRLEN_LITERAL("\\n")); break;
          case '\r': put_datapl(out, PTRLEN_LITERAL("\\r")); break;
          case '\t': put_datapl(out, PTRLEN_LITERAL("\\t")); break;
          default:
            if (c < 0x20 || c == 0x7F)
                put_fmt(out, "\\u%04x", c);
            else
                put_byte(out, c);
        }
    }
    put_byte(out, '"');
}

static void jw_value(const JsonValue *v, strbuf *out, int depth)
{
    switch (v->type) {
      case JSON_NULL:
        put_datapl(out, PTRLEN_LITERAL("null"));
        break;
      case JSON_BOOL:
        put_dataz(out, v->u.b ? "true" : "false");
        break;
      case JSON_NUMBER:
        put_fmt(out, "%lld", v->u.n);
        break;
      case JSON_STRING:
        jw_string(out, v->u.s);
        break;
      case JSON_ARRAY:
        if (!v->u.arr.len) {
            put_datapl(out, PTRLEN_LITERAL("[]"));
            break;
        }
        put_datapl(out, PTRLEN_LITERAL("[\n"));
        for (size_t i = 0; i < v->u.arr.len; i++) {
            jw_indent(out, depth + 1);
            jw_value(v->u.arr.items[i], out, depth + 1);
            if (i + 1 < v->u.arr.len)
                put_byte(out, ',');
            put_byte(out, '\n');
        }
        jw_indent(out, depth);
        put_byte(out, ']');
        break;
      case JSON_OBJECT:
        if (!v->u.obj.len) {
            put_datapl(out, PTRLEN_LITERAL("{}"));
            break;
        }
        put_datapl(out, PTRLEN_LITERAL("{\n"));
        for (size_t i = 0; i < v->u.obj.len; i++) {
            jw_indent(out, depth + 1);
            jw_string(out, v->u.obj.members[i].key);
            put_datapl(out, PTRLEN_LITERAL(": "));
            jw_value(v->u.obj.members[i].value, out, depth + 1);
            if (i + 1 < v->u.obj.len)
                put_byte(out, ',');
            put_byte(out, '\n');
        }
        jw_indent(out, depth);
        put_byte(out, '}');
        break;
    }
}

void json_write(const JsonValue *v, strbuf *out)
{
    jw_value(v, out, 0);
    put_byte(out, '\n');
}
