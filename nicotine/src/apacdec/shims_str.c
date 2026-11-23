/* Apple arm64 libc++ pieces with Apple's object layouts.
 * std::string (alternate layout): long = { char *data; size_t size; size_t cap | 1<<63 },
 * short = 23 bytes of characters + one byte holding the size (top bit clear). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "loader.h"
typedef union { struct { char *data; size_t size, cap; } l; struct { char data[23]; unsigned char size; } s; } astr;
#define LONGBIT 0x8000000000000000UL
static int is_long(const astr *s) { return s->s.size & 0x80; }
static char *s_data(astr *s) { return is_long(s) ? s->l.data : s->s.data; }
static size_t s_size(const astr *s) { return is_long(s) ? s->l.size : s->s.size; }
static size_t s_cap(const astr *s) { return is_long(s) ? (s->l.cap & ~LONGBIT) - 1 : 22; }
static void s_setsize(astr *s, size_t n) { if (is_long(s)) s->l.size = n; else s->s.size = (unsigned char)n; s_data(s)[n] = 0; }
static void s_reserve(astr *s, size_t want) {
	if (want <= s_cap(s)) return;
	size_t cap = (want < 2 * s_cap(s) ? 2 * s_cap(s) : want) + 1; cap = (cap + 15) & ~15UL;
	char *p = malloc(cap); size_t n = s_size(s); memcpy(p, s_data(s), n + 1);
	if (is_long(s)) free(s->l.data);
	s->l.data = p; s->l.size = n; s->l.cap = cap | LONGBIT;
}
static void s_init(astr *s, const char *p, size_t n) { memset(s, 0, sizeof *s); s_reserve(s, n); memcpy(s_data(s), p, n); s_setsize(s, n); }
static astr *str_append(astr *s, const char *p, size_t n) { size_t z = s_size(s); s_reserve(s, z + n); memmove(s_data(s) + z, p, n); s_setsize(s, z + n); return s; }
static astr *str_append_cstr(astr *s, const char *p) { return str_append(s, p, strlen(p)); }
static void str_push_back(astr *s, char c) { str_append(s, &c, 1); }
static void str_resize(astr *s, size_t n, char c) { size_t z = s_size(s); if (n > z) { s_reserve(s, n); memset(s_data(s) + z, c, n - z); } s_setsize(s, n); }
static astr *str_insert(astr *s, size_t pos, const char *p, size_t n) {
	size_t z = s_size(s); if (pos > z) pos = z; char *t = malloc(n + 1); memcpy(t, p, n);
	s_reserve(s, z + n); char *d = s_data(s); memmove(d + pos + n, d + pos, z - pos); memcpy(d + pos, t, n); free(t); s_setsize(s, z + n); return s;
}
static astr *str_assign(astr *s, const astr *o) { if (s != o) { size_t n = s_size(o); s_reserve(s, n); memmove(s_data(s), s_data((astr *)o), n); s_setsize(s, n); } return s; }
static astr *str_assign_cstr(astr *s, const char *p) { size_t n = strlen(p); s_reserve(s, n); memmove(s_data(s), p, n); s_setsize(s, n); return s; }
static int str_compare(const astr *s, const char *p) { size_t a = s_size(s), b = strlen(p); int r = memcmp(s_data((astr *)s), p, a < b ? a : b); return r ? r : a < b ? -1 : a > b; }
static void str_ctor_sub(astr *s, const astr *o, size_t pos, size_t n, void *alloc) { size_t z = s_size(o); if (pos > z) pos = z; if (n > z - pos) n = z - pos; s_init(s, s_data((astr *)o) + pos, n); }
static void str_ctor_copy(astr *s, const astr *o) { s_init(s, s_data((astr *)o), s_size(o)); }
static void str_dtor(astr *s) { if (is_long(s)) free(s->l.data); }
static void str_grow_replace(astr *s, size_t old_cap, size_t delta_cap, size_t old_sz, size_t n_copy, size_t n_del, size_t n_add, const char *p) {
	size_t tail = old_sz - n_del - n_copy, cap = ((old_cap + delta_cap) * 2 + 16) & ~15UL; char *d = malloc(cap), *o = s_data(s);
	memcpy(d, o, n_copy); if (n_add) memcpy(d + n_copy, p, n_add); memcpy(d + n_copy + n_add, o + n_copy + n_del, tail);
	if (is_long(s)) free(s->l.data);
	s->l.data = d; s->l.size = n_copy + n_add + tail; s->l.cap = cap | LONGBIT; d[s->l.size] = 0;
}
static int str_stoi(const astr *s, size_t *idx, int base) { char *e; const char *p = s_data((astr *)s); long v = strtol(p, &e, base); if (idx) *idx = e - p; return (int)v; }

/* locks: one thread here */
static void nop(void *a) { }
static void call_once(volatile unsigned long *flag, void *arg, void (*fn)(void *)) { if (*flag == 0) { *flag = 1; fn(arg); *flag = ~0UL; } }

/* exception objects: { vptr, message }. The library stores its own vptr (imported vtable + 16) after
 * calling the constructor, so each imported vtable is a small table with the same slots. */
typedef struct { void **vt; const char *msg; } exc;
static void exc_dtor(exc *e) { }
static const char *exc_what(exc *e) { return e->msg && (uintptr_t)e->msg > 0x10000 ? e->msg : "(no message)"; }
#define VT(n) static void *n[] = { 0, 0, exc_dtor, exc_dtor, exc_what }
VT(vt_logic); VT(vt_length); VT(vt_range); VT(vt_overflow); VT(vt_runtime); VT(vt_optional); VT(vt_variant); VT(vt_anycast); VT(vt_alloc); VT(vt_cast); VT(vt_newlen); VT(vt_regex);
static void logic_ctor(exc *e, const char *m) { e->vt = vt_logic + 2; e->msg = strdup(m); }
static void runtime_ctor(exc *e, const char *m) { e->vt = vt_runtime + 2; e->msg = strdup(m); }
static void alloc_ctor(exc *e) { e->vt = vt_alloc + 2; }
static void cast_ctor(exc *e) { e->vt = vt_cast + 2; }
static void newlen_ctor(exc *e) { e->vt = vt_newlen + 2; }
static void regex_ctor(exc *e, int code) { static char b[40]; snprintf(b, sizeof b, "regex error %d", code); e->vt = vt_regex + 2; e->msg = b; }
static void *std_align(size_t al, size_t sz, void **ptr, size_t *space) {
	uintptr_t p = (uintptr_t)*ptr, a = (p + al - 1) & ~(al - 1); if (a - p + sz > *space) return NULL; *space -= a - p; *ptr = (void *)a; return (void *)a;
}
static int cmp_u8(const void *a, const void *b) { return *(const unsigned char *)a - *(const unsigned char *)b; }
static void sort_u8(unsigned char *a, unsigned char *b, void *less) { qsort(a, b - a, 1, cmp_u8); }
const shim_t shims_str[] = {
	{ "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEPKcm", str_append }, { "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEPKc", str_append_cstr },
	{ "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE9push_backEc", str_push_back }, { "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6resizeEmc", str_resize },
	{ "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6insertEmPKcm", str_insert }, { "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEaSERKS5_", str_assign },
	{ "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6assignEPKc", str_assign_cstr }, { "__ZNKSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE7compareEPKc", str_compare },
	{ "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEC2ERKS5_mmRKS4_", str_ctor_sub }, { "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEC1ERKS5_", str_ctor_copy },
	{ "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEED1Ev", str_dtor },
	{ "__ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE21__grow_by_and_replaceEmmmmmmPKc", str_grow_replace },
	{ "__ZNSt3__14stoiERKNS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEPmi", str_stoi },
	{ "__ZNSt3__115recursive_mutexC1Ev", nop }, { "__ZNSt3__115recursive_mutexD1Ev", nop }, { "__ZNSt3__115recursive_mutex4lockEv", nop }, { "__ZNSt3__115recursive_mutex6unlockEv", nop },
	{ "__ZNSt3__15mutex4lockEv", nop }, { "__ZNSt3__15mutex6unlockEv", nop }, { "__ZNSt3__15mutexD1Ev", nop }, { "__ZNSt3__111__call_onceERVmPvPFvS2_E", call_once },
	{ "__ZNSt11logic_errorC1EPKc", logic_ctor }, { "__ZNSt11logic_errorC2EPKc", logic_ctor }, { "__ZNSt13runtime_errorC1EPKc", runtime_ctor }, { "__ZNSt13runtime_errorC2EPKc", runtime_ctor },
	{ "__ZNSt9bad_allocC1Ev", alloc_ctor }, { "__ZNSt8bad_castC1Ev", cast_ctor }, { "__ZNSt8bad_castC2Ev", cast_ctor }, { "__ZNSt20bad_array_new_lengthC1Ev", newlen_ctor },
	{ "__ZNSt3__111regex_errorC1ENS_15regex_constants10error_typeE", regex_ctor },
	{ "__ZNSt12length_errorD1Ev", exc_dtor }, { "__ZNSt12out_of_rangeD1Ev", exc_dtor }, { "__ZNSt13runtime_errorD1Ev", exc_dtor }, { "__ZNSt13runtime_errorD2Ev", exc_dtor }, { "__ZNSt14overflow_errorD1Ev", exc_dtor },
	{ "__ZNSt19bad_optional_accessD1Ev", exc_dtor }, { "__ZNSt20bad_array_new_lengthD1Ev", exc_dtor }, { "__ZNSt3__111regex_errorD1Ev", exc_dtor }, { "__ZNSt8bad_castD1Ev", exc_dtor },
	{ "__ZNSt8bad_castD2Ev", exc_dtor }, { "__ZNSt9bad_allocD1Ev", exc_dtor }, { "__ZNSt9exceptionD2Ev", exc_dtor }, { "__ZNSt11logic_errorD2Ev", exc_dtor },
	{ "__ZTVSt12length_error", vt_length }, { "__ZTVSt12out_of_range", vt_range }, { "__ZTVSt14overflow_error", vt_overflow }, { "__ZTVSt18bad_variant_access", vt_variant },
	{ "__ZTVSt19bad_optional_access", vt_optional }, { "__ZTVSt12bad_any_cast", vt_anycast }, { "__ZTVSt9bad_alloc", vt_alloc },
	{ "__ZNSt3__15alignEmmRPvRm", std_align }, { "__ZNSt3__16__sortIRNS_6__lessIhhEEPhEEvT0_S5_T_", sort_u8 },
	{ 0, 0 } };
