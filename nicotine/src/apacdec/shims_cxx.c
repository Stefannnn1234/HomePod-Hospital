/* C++ runtime pieces the library imports (Apple libc++ / libc++abi). Exceptions cannot unwind
 * through the library's frames here, so a throw reports what was thrown and stops. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "loader.h"
#include <setjmp.h>
jmp_buf *g_throw_jmp; int g_throw_quiet;
extern void *_ZTVN10__cxxabiv117__class_type_infoE[], *_ZTVN10__cxxabiv120__si_class_type_infoE[], *_ZTVN10__cxxabiv116__enum_type_infoE[], *_ZTVN10__cxxabiv121__vmi_class_type_infoE[];
extern void *__dynamic_cast(const void *, const void *, const void *, long);
static void *op_new(size_t n) { void *p = malloc(n ? n : 1); if (!p) { fprintf(stderr, "out of memory\n"); exit(75); } return p; }
static void *op_new_nt(size_t n, void *nt) { return malloc(n ? n : 1); }
static void op_del(void *p) { free(p); }
static void pure_virtual(void) { fprintf(stderr, "pure virtual call\n"); exit(76); }
static int guard_acquire(uint64_t *g) { return *(char *)g == 0; }
static void guard_release(uint64_t *g) { *(char *)g = 1; }
static void guard_abort(uint64_t *g) { }
static void *cxa_alloc(size_t n) { return calloc(1, n + 128) + 64; }
static void cxa_free(void *p) { }
static void *ti_int[2] = { 0, "i" }, *ti_cstr[2] = { 0, "PKc" }, *ti_uint[2] = { 0, "j" }, *ti_long[2] = { 0, "l" };
static void cxa_throw(void *obj, void **tinfo, void *dtor) {
	const char *n = tinfo ? (const char *)((uint64_t)tinfo[1] & 0x7FFFFFFFFFFFFFFFULL) : "?";
	if (g_throw_quiet && g_throw_jmp) longjmp(*g_throw_jmp, 1);
	fprintf(stderr, "\n*** C++ exception thrown from %p, type %s", __builtin_return_address(0), n);
	if (tinfo == ti_int || tinfo == ti_uint) { int v = *(int *)obj; char b[5] = { v >> 24, v >> 16, v >> 8, v, 0 }; fprintf(stderr, ": %d (%#x '%s')", v, v, b); }
	else if (tinfo == ti_cstr) fprintf(stderr, ": %s", *(const char **)obj);
	/* std::exception-like objects: slot 2 of the vtable is what() */
	else if (n && (strstr(n, "error") || strstr(n, "xception"))) {
		void ***o = obj; const char *(*what)(void *) = (const char *(*)(void *))(*o)[2];
		fprintf(stderr, ": %s", what(obj));
	}
	fprintf(stderr, "\n");
	if (g_throw_jmp) longjmp(*g_throw_jmp, 1);      /* the caller abandons this call and resets the codec */
	exit(74);
}
static void cxa_rethrow(void) { fprintf(stderr, "rethrow\n"); exit(74); }
static void *cxa_begin_catch(void *e) { return e; }
static void cxa_end_catch(void) { }
static void terminate(void) { fprintf(stderr, "std::terminate\n"); exit(77); }
static char nothrow_obj;
/* std::__1::__shared_weak_count: { vptr, long shared_owners, long shared_weak_owners } */
typedef struct swc { void **vt; long shared, weak; } swc;
static void swc_release_weak(swc *c) { if (__sync_fetch_and_sub(&c->weak, 1) == 0) ((void (*)(swc *))c->vt[4])(c); }
static void *swc_get_deleter(const swc *c, void *ti) { return NULL; }
static void swc_dtor(swc *c) { }
static swc *swc_lock(swc *c) { for (long o = c->shared; o != -1; o = c->shared) if (__sync_bool_compare_and_swap(&c->shared, o, o + 1)) return c; return NULL; }
/* std::exception / logic_error family: object = { vptr, const char *msg } here */
static const char *exc_what(void *e) { return "std::exception"; }
const shim_t shims_cxx[] = {
	{ "__Znwm", op_new }, { "__Znam", op_new }, { "__ZdlPv", op_del }, { "__ZdaPv", op_del }, { "__ZnwmRKSt9nothrow_t", op_new_nt }, { "__ZSt7nothrow", &nothrow_obj },
	{ "___cxa_pure_virtual", pure_virtual }, { "___cxa_guard_acquire", guard_acquire }, { "___cxa_guard_release", guard_release }, { "___cxa_guard_abort", guard_abort },
	{ "___cxa_allocate_exception", cxa_alloc }, { "___cxa_free_exception", cxa_free }, { "___cxa_throw", cxa_throw }, { "___cxa_rethrow", cxa_rethrow },
	{ "___cxa_begin_catch", cxa_begin_catch }, { "___cxa_end_catch", cxa_end_catch }, { "__ZSt9terminatev", terminate },
	{ "__ZTVN10__cxxabiv117__class_type_infoE", _ZTVN10__cxxabiv117__class_type_infoE }, { "__ZTVN10__cxxabiv120__si_class_type_infoE", _ZTVN10__cxxabiv120__si_class_type_infoE },
	{ "__ZTVN10__cxxabiv116__enum_type_infoE", _ZTVN10__cxxabiv116__enum_type_infoE }, { "__ZTVN10__cxxabiv121__vmi_class_type_infoE", _ZTVN10__cxxabiv121__vmi_class_type_infoE },
	{ "___dynamic_cast", __dynamic_cast }, { "__ZTIi", ti_int }, { "__ZTIPKc", ti_cstr }, { "__ZTIj", ti_uint }, { "__ZTIl", ti_long },
	{ "__ZNSt3__119__shared_weak_count14__release_weakEv", swc_release_weak }, { "__ZNKSt3__119__shared_weak_count13__get_deleterERKSt9type_info", swc_get_deleter },
	{ "__ZNSt3__119__shared_weak_countD2Ev", swc_dtor }, { "__ZNSt3__119__shared_weak_count4lockEv", swc_lock },
	{ "__ZNKSt9exception4whatEv", exc_what },
	{ 0, 0 } };
