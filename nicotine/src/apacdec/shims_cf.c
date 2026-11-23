/* A very small CoreFoundation: strings, numbers, booleans, data, arrays, dictionaries.
 * Every object starts with { isa, info }: isa points at one of the class markers below, which is
 * also how the library's own constant strings (isa = __CFConstantStringClassReference) are recognised. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "loader.h"
typedef const void *CFTypeRef;
static long cls_const_string[8], cls_string, cls_number, cls_boolean, cls_data, cls_array, cls_dict;
typedef struct { void *isa; uint64_t info; } hdr;
typedef struct { hdr h; const char *s; long len; } cfstr;            /* same layout as a compiler-made constant string */
typedef struct { hdr h; long rc; char *s; long len; } cfmstr;
typedef struct { hdr h; long rc; int type; union { long long i; double d; } v; } cfnum;
typedef struct { hdr h; long rc; long len; uint8_t *p; } cfdata;
typedef struct { hdr h; long rc; long n, cap; const void **v; } cfarr;
typedef struct { hdr h; long rc; long n, cap; const void **k, **v; } cfdict;
static struct { hdr h; long rc; int v; } bool_true = { { &cls_boolean, 0 }, 1 << 30, 1 }, bool_false = { { &cls_boolean, 0 }, 1 << 30, 0 };
static const void *kTrue = &bool_true, *kFalse = &bool_false;
enum { T_STRING = 7, T_NUMBER = 22, T_BOOLEAN = 21, T_DATA = 20, T_ARRAY = 19, T_DICT = 18 };
static unsigned long type_of(CFTypeRef o) {
	void *isa = ((const hdr *)o)->isa;
	if (isa == cls_const_string || isa == &cls_string) return T_STRING;
	if (isa == &cls_number) return T_NUMBER; if (isa == &cls_boolean) return T_BOOLEAN; if (isa == &cls_data) return T_DATA;
	if (isa == &cls_array) return T_ARRAY; if (isa == &cls_dict) return T_DICT;
	return 0;
}
static const char *str_c(CFTypeRef o, long *len) {
	if (!o) { if (len) *len = 0; return ""; }
	if (((const hdr *)o)->isa == cls_const_string) { const cfstr *s = o; if (len) *len = s->len; return s->s; }
	const cfmstr *m = o; if (len) *len = m->len; return m->s;
}
static void *alloc(size_t n, void *cls) { hdr *h = calloc(1, n); h->isa = cls; ((long *)(h + 1))[0] = 1; return h; }
static CFTypeRef CFRetain(CFTypeRef o) { if (o && ((const hdr *)o)->isa != cls_const_string) ((long *)((hdr *)o + 1))[0]++; return o; }
static void CFRelease(CFTypeRef o) { /* objects are few and small in this process: never freed */ }
static unsigned long CFGetTypeID(CFTypeRef o) { return type_of(o); }
static unsigned long id_string(void) { return T_STRING; } static unsigned long id_number(void) { return T_NUMBER; } static unsigned long id_boolean(void) { return T_BOOLEAN; }
static unsigned long id_data(void) { return T_DATA; } static unsigned long id_array(void) { return T_ARRAY; } static unsigned long id_dict(void) { return T_DICT; }
/* strings */
static CFTypeRef mkstr(const char *s, long n) { cfmstr *m = alloc(sizeof *m, &cls_string); m->s = malloc(n + 1); memcpy(m->s, s, n); m->s[n] = 0; m->len = n; return m; }
static CFTypeRef CFStringCreateWithCString(void *a, const char *s, unsigned enc) { return s ? mkstr(s, strlen(s)) : NULL; }
static CFTypeRef CFStringCreateWithBytes(void *a, const uint8_t *b, long n, unsigned enc, int ext) { return mkstr((const char *)b, n); }
static CFTypeRef CFStringCreateMutableCopy(void *a, long max, CFTypeRef s) { long n; const char *c = str_c(s, &n); return mkstr(c, n); }
static void CFStringAppend(CFTypeRef d, CFTypeRef s) { cfmstr *m = (cfmstr *)d; long n; const char *c = str_c(s, &n); m->s = realloc(m->s, m->len + n + 1); memcpy(m->s + m->len, c, n + 1); m->len += n; }
static long CFStringGetLength(CFTypeRef s) { long n; str_c(s, &n); return n; }
static const char *CFStringGetCStringPtr(CFTypeRef s, unsigned enc) { return str_c(s, NULL); }
static int CFStringGetCString(CFTypeRef s, char *buf, long size, unsigned enc) { long n; const char *c = str_c(s, &n); if (n + 1 > size) return 0; memcpy(buf, c, n); buf[n] = 0; return 1; }
static long CFStringCompare(CFTypeRef a, CFTypeRef b, unsigned long opt) { int r = strcmp(str_c(a, 0), str_c(b, 0)); return r < 0 ? -1 : r > 0; }
typedef struct { long loc, len; } CFRange;
static long CFStringGetBytes(CFTypeRef s, CFRange r, unsigned enc, uint8_t loss, int ext, uint8_t *buf, long max, long *used) {
	long n; const char *c = str_c(s, &n); long k = r.len < max || !buf ? r.len : max; if (buf) memcpy(buf, c + r.loc, k); if (used) *used = k; return k; }
/* numbers: CFNumberType 1..6 integers (3 = SInt32, 4 = SInt64), 5/12 float32, 6/13 float64, 9 int, 10 long, 11 long long, 14 CFIndex */
static int is_float(int t) { return t == 5 || t == 6 || t == 12 || t == 13 || t == 16; }
static int num_size(int t) { switch (t) { case 1: case 7: return 1; case 2: case 8: return 2; case 3: case 9: case 5: case 12: return 4; default: return 8; } }
static CFTypeRef CFNumberCreate(void *a, long t, const void *p) {
	cfnum *n = alloc(sizeof *n, &cls_number); n->type = (int)t;
	if (is_float((int)t)) n->v.d = num_size((int)t) == 4 ? *(const float *)p : *(const double *)p;
	else switch (num_size((int)t)) { case 1: n->v.i = *(const int8_t *)p; break; case 2: n->v.i = *(const int16_t *)p; break; case 4: n->v.i = *(const int32_t *)p; break; default: n->v.i = *(const int64_t *)p; }
	return n; }
static long CFNumberGetType(CFTypeRef o) { return ((const cfnum *)o)->type; }
static int CFNumberGetValue(CFTypeRef o, long t, void *p) {
	const cfnum *n = o; double d = is_float(n->type) ? n->v.d : (double)n->v.i; long long i = is_float(n->type) ? (long long)n->v.d : n->v.i;
	if (is_float((int)t)) { if (num_size((int)t) == 4) *(float *)p = (float)d; else *(double *)p = d; }
	else switch (num_size((int)t)) { case 1: *(int8_t *)p = (int8_t)i; break; case 2: *(int16_t *)p = (int16_t)i; break; case 4: *(int32_t *)p = (int32_t)i; break; default: *(int64_t *)p = i; }
	return 1; }
static int CFBooleanGetValue(CFTypeRef o) { return o == kTrue; }
/* data */
static CFTypeRef CFDataCreate(void *a, const uint8_t *b, long n) { cfdata *d = alloc(sizeof *d, &cls_data); d->p = malloc(n ? n : 1); memcpy(d->p, b, n); d->len = n; return d; }
static const uint8_t *CFDataGetBytePtr(CFTypeRef o) { return ((const cfdata *)o)->p; }
static long CFDataGetLength(CFTypeRef o) { return ((const cfdata *)o)->len; }
/* arrays */
static CFTypeRef CFArrayCreateMutable(void *a, long cap, const void *cb) { return alloc(sizeof(cfarr), &cls_array); }
static void CFArrayAppendValue(CFTypeRef o, const void *v) { cfarr *a = (cfarr *)o; if (a->n == a->cap) { a->cap = a->cap ? a->cap * 2 : 8; a->v = realloc(a->v, a->cap * sizeof *a->v); } a->v[a->n++] = v; }
static CFTypeRef CFArrayCreate(void *al, const void **v, long n, const void *cb) { CFTypeRef a = CFArrayCreateMutable(0, 0, 0); for (long i = 0; i < n; i++) CFArrayAppendValue(a, v[i]); return a; }
static long CFArrayGetCount(CFTypeRef o) { return ((const cfarr *)o)->n; }
static const void *CFArrayGetValueAtIndex(CFTypeRef o, long i) { const cfarr *a = o; return i >= 0 && i < a->n ? a->v[i] : NULL; }
static void CFArrayGetValues(CFTypeRef o, CFRange r, const void **out) { const cfarr *a = o; for (long i = 0; i < r.len; i++) out[i] = a->v[r.loc + i]; }
/* dictionaries: keys are strings (compared by content) or anything else (by pointer) */
static int key_eq(const void *a, const void *b) { if (a == b) return 1; return type_of(a) == T_STRING && type_of(b) == T_STRING && !strcmp(str_c(a, 0), str_c(b, 0)); }
static long dict_find(const cfdict *d, const void *k) { for (long i = 0; i < d->n; i++) if (key_eq(d->k[i], k)) return i; return -1; }
static CFTypeRef CFDictionaryCreateMutable(void *a, long cap, const void *kc, const void *vc) { return alloc(sizeof(cfdict), &cls_dict); }
static void CFDictionarySetValue(CFTypeRef o, const void *k, const void *v) {
	cfdict *d = (cfdict *)o; long i = dict_find(d, k); if (i >= 0) { d->v[i] = v; return; }
	if (d->n == d->cap) { d->cap = d->cap ? d->cap * 2 : 8; d->k = realloc(d->k, d->cap * sizeof *d->k); d->v = realloc(d->v, d->cap * sizeof *d->v); }
	d->k[d->n] = k; d->v[d->n++] = v; }
static void CFDictionaryAddValue(CFTypeRef o, const void *k, const void *v) { if (dict_find(o, k) < 0) CFDictionarySetValue(o, k, v); }
static const void *CFDictionaryGetValue(CFTypeRef o, const void *k) { if (!o) return NULL; const cfdict *d = o; long i = dict_find(d, k); return i < 0 ? NULL : d->v[i]; }
static int CFDictionaryGetValueIfPresent(CFTypeRef o, const void *k, const void **v) { if (!o) return 0; const cfdict *d = o; long i = dict_find(d, k); if (i < 0) return 0; if (v) *v = d->v[i]; return 1; }
static int CFDictionaryContainsKey(CFTypeRef o, const void *k) { return o && dict_find(o, k) >= 0; }
static long CFDictionaryGetCount(CFTypeRef o) { return ((const cfdict *)o)->n; }
static void CFDictionaryGetKeysAndValues(CFTypeRef o, const void **k, const void **v) { const cfdict *d = o; for (long i = 0; i < d->n; i++) { if (k) k[i] = d->k[i]; if (v) v[i] = d->v[i]; } }
/* things with no meaning here */
static CFTypeRef none(void) { return NULL; }
static long callbacks[8];
static cfstr version_key = { { cls_const_string, 0x7c8 }, "ProductVersion", 14 };
static const void *version_key_p = &version_key;
#define F(n) { "_" #n, (void *)n }
const shim_t shims_cf[] = {
	F(CFRetain), F(CFRelease), F(CFGetTypeID), F(CFStringCreateWithCString), F(CFStringCreateWithBytes), F(CFStringCreateMutableCopy), F(CFStringAppend),
	F(CFStringGetLength), F(CFStringGetCStringPtr), F(CFStringGetCString), F(CFStringCompare), F(CFStringGetBytes), F(CFNumberCreate), F(CFNumberGetType),
	F(CFNumberGetValue), F(CFBooleanGetValue), F(CFDataCreate), F(CFDataGetBytePtr), F(CFDataGetLength), F(CFArrayCreateMutable), F(CFArrayAppendValue),
	F(CFArrayCreate), F(CFArrayGetCount), F(CFArrayGetValueAtIndex), F(CFArrayGetValues), F(CFDictionaryCreateMutable), F(CFDictionarySetValue),
	F(CFDictionaryAddValue), F(CFDictionaryGetValue), F(CFDictionaryGetValueIfPresent), F(CFDictionaryContainsKey), F(CFDictionaryGetCount), F(CFDictionaryGetKeysAndValues),
	{ "_CFStringGetTypeID", id_string }, { "_CFNumberGetTypeID", id_number }, { "_CFBooleanGetTypeID", id_boolean }, { "_CFDataGetTypeID", id_data },
	{ "_CFArrayGetTypeID", id_array }, { "_CFDictionaryGetTypeID", id_dict },
	{ "_CFBundleGetBundleWithIdentifier", none }, { "_CFBundleCopyLocalizedString", none }, { "_CFPreferencesCopyAppValue", none }, { "__CFCopySupplementalVersionDictionary", none },
	{ "___CFConstantStringClassReference", cls_const_string }, { "_kCFBooleanTrue", &kTrue }, { "_kCFBooleanFalse", &kFalse },
	{ "_kCFTypeArrayCallBacks", callbacks }, { "_kCFTypeDictionaryKeyCallBacks", callbacks }, { "_kCFTypeDictionaryValueCallBacks", callbacks },
	{ "__kCFSystemVersionProductVersionKey", &version_key_p },
	{ 0, 0 } };
const char *cf_cstr(const void *s) { return s ? str_c(s, NULL) : "(null)"; }
