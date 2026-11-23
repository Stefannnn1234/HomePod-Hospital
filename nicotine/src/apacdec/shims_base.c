/* C library, maths, logging and Darwin odds and ends. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <time.h>
#include <wchar.h>
#include <arm_neon.h>
#include "loader.h"
/* ---- Darwin passes variadic arguments on the stack only; rebuild a va_list from there ---- */
typedef struct { void *stack, *gr_top, *vr_top; int gr_offs, vr_offs; } aapcs_va;
#define DARWIN_VA(ap, args) va_list ap; { aapcs_va *v_ = (aapcs_va *)&ap; v_->stack = (args); v_->gr_top = v_->vr_top = 0; v_->gr_offs = v_->vr_offs = 0; }
int d_snprintf_c(char *b, size_t n, const char *fmt, void *args) { DARWIN_VA(ap, args); return vsnprintf(b, n, fmt, ap); }
int d_printf_c(const char *fmt, void *args) { DARWIN_VA(ap, args); return vfprintf(stderr, fmt, ap); }
int d_fprintf_c(FILE *f, const char *fmt, void *args) { DARWIN_VA(ap, args); return vfprintf(f ? f : stderr, fmt, ap); }
int d_sscanf_c(const char *s, const char *fmt, void *args) { DARWIN_VA(ap, args); return vsscanf(s, fmt, ap); }
__asm__(".text\n"
 ".global d_snprintf\nd_snprintf: mov x3, sp\n b d_snprintf_c\n"
 ".global d_printf\nd_printf: mov x1, sp\n b d_printf_c\n"
 ".global d_fprintf\nd_fprintf: mov x2, sp\n b d_fprintf_c\n"
 ".global d_sscanf\nd_sscanf: mov x2, sp\n b d_sscanf_c\n"
 ".global d_chkstk\nd_chkstk: ret\n");
extern void d_snprintf(void), d_printf(void), d_fprintf(void), d_sscanf(void), d_chkstk(void);
static int d_vsnprintf(char *b, size_t n, const char *fmt, void *darwin_va) { DARWIN_VA(ap, darwin_va); return vsnprintf(b, n, fmt, ap); }
/* ---- data objects ---- */
static uint64_t stack_guard = 0x5a5aa5a5c3c33c3cULL;
static FILE *d_stderr, *d_stdout, *d_stdin;
static uint32_t task_self = 0x103;
static struct { char dummy[64]; } os_log_default;
static struct { char magic[8], enc[32]; void *f1, *f2; int inv; uint32_t runetype[256], lower[256], upper[256]; } rune_locale;
__attribute__((constructor)) static void init_data(void) {
	d_stderr = stderr; d_stdout = stdout; d_stdin = stdin;
	for (int c = 0; c < 128; c++) {
		uint32_t t = 0;
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) t |= 0x100;
		if (c < 32 || c == 127) t |= 0x200;
		if (c >= '0' && c <= '9') t |= 0x400 | 0x10000;
		if (c > 32 && c < 127) t |= 0x800;
		if (c >= 'a' && c <= 'z') t |= 0x1000;
		if (c > 32 && c < 127 && !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) t |= 0x2000;
		if (c == ' ' || (c >= 9 && c <= 13)) t |= 0x4000;
		if (c >= 'A' && c <= 'Z') t |= 0x8000;
		if ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) t |= 0x10000;
		if (c == ' ' || c == '\t') t |= 0x20000;
		if (c >= 32 && c < 127) t |= 0x40000;
		rune_locale.runetype[c] = t;
	}
	for (int c = 0; c < 256; c++) { rune_locale.lower[c] = (c >= 'A' && c <= 'Z') ? c + 32 : c; rune_locale.upper[c] = (c >= 'a' && c <= 'z') ? c - 32 : c; }
}
/* ---- functions ---- */
static void d_bzero(void *p, size_t n) { memset(p, 0, n); }
static void d_pat4(void *b, const void *p, size_t n) { for (size_t i = 0; i < n; i++) ((char *)b)[i] = ((const char *)p)[i & 3]; }
static void d_pat16(void *b, const void *p, size_t n) { for (size_t i = 0; i < n; i++) ((char *)b)[i] = ((const char *)p)[i & 15]; }
static size_t d_strlcpy(char *d, const char *s, size_t n) { size_t l = strlen(s); if (n) { size_t k = l < n - 1 ? l : n - 1; memcpy(d, s, k); d[k] = 0; } return l; }
static void *d_memcpy_chk(void *d, const void *s, size_t n, size_t dn) { return memcpy(d, s, n); }
static void *d_memmove_chk(void *d, const void *s, size_t n, size_t dn) { return memmove(d, s, n); }
static void *d_memset_chk(void *d, int c, size_t n, size_t dn) { return memset(d, c, n); }
static void d_assert(const char *fn, const char *file, int line, const char *e) { fprintf(stderr, "assertion failed: %s (%s:%d %s)\n", e, file, line, fn); exit(71); }
static void d_stack_fail(void) { fprintf(stderr, "stack check failed\n"); exit(72); }
static void d_unwind_resume(void *e) { fprintf(stderr, "C++ exception unwinding is not supported here\n"); exit(73); }
typedef struct { double s, c; } sc_d; typedef struct { float s, c; } sc_f;
static sc_d d_sincos(double x) { sc_d r = { sin(x), cos(x) }; return r; }
static sc_f d_sincosf(float x) { sc_f r = { sinf(x), cosf(x) }; return r; }
static float d_cospif(float x) { return cosf((float)M_PI * x); }
static double d_exp10(double x) { return pow(10.0, x); }
static float d_exp10f(float x) { return powf(10.0f, x); }
static float32x4_t d_log10_f4(float32x4_t v) { float a[4]; vst1q_f32(a, v); for (int i = 0; i < 4; i++) a[i] = log10f(a[i]); return vld1q_f32(a); }
static float32x4_t d_log2_f4(float32x4_t v) { float a[4]; vst1q_f32(a, v); for (int i = 0; i < 4; i++) a[i] = log2f(a[i]); return vld1q_f32(a); }
static int d_maskrune(int c, unsigned long f) { return (c >= 0 && c < 256) ? (int)(rune_locale.runetype[c] & f) : 0; }
static int d_tolower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
static int d_toupper(int c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }
static uint64_t d_mach_absolute_time(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec; }
static int d_mach_timebase_info(uint32_t *i) { i[0] = 1; i[1] = 1; return 0; }
static void *d_os_log_create(const char *a, const char *b) { return &os_log_default; }
static int d_os_log_type_enabled(void *l, int t) { return g_trace > 1; }
static void d_os_log_impl(void *dso, void *log, int type, const char *fmt, uint8_t *buf, uint32_t size) { if (g_trace > 1) fprintf(stderr, "[os_log] %s\n", fmt); }
static int d_lock(void *l) { return 0; }
static int d_trylock(void *l) { return 1; }
/* blocks: { isa, flags, reserved, invoke, ... } */
static void d_dispatch_once(long *pred, void *block) { if (*pred == 0) { *pred = ~0L; ((void (*)(void *))(((void **)block)[2]))(block); } }
static void *block_global[4], *block_stack[4];
static int d_posix_memalign(void **p, size_t a, size_t n) { return posix_memalign(p, a < sizeof(void *) ? sizeof(void *) : a, n); }
static char *d_getenv(const char *n) { return NULL; }
#define D(n) { "_" #n, (void *)n }
#define P(n) { "__platform_" #n, (void *)n }
const shim_t shims_base[] = {
	D(abort), D(acos), D(acosf), D(asin), D(asinf), D(atan), D(atan2), D(atan2f), D(atanf), D(calloc), D(cos), D(cosf), D(exit), D(exp), D(exp2), D(exp2f),
	D(expf), D(fclose), D(fmod), D(fmodf), D(free), D(frexp), D(frexpf), D(fwrite), D(hypot), D(ldexp), D(ldexpf), D(log), D(log10), D(log10f), D(log2f), D(logf),
	D(malloc), D(memmem), D(pow), D(powf), D(qsort), D(random), D(realloc), D(sin), D(sinf), D(sinh), D(strrchr), D(strtod), D(tan), D(tanf), D(wmemchr), D(scalbnf),
	D(memchr), D(memcmp), D(memcpy), D(memmove), D(memset), D(strchr), D(strcmp), D(strlen), D(strncmp), D(strncpy),
	P(memchr), P(memcmp), P(memmove), P(memset), P(strchr), P(strcmp), P(strlen), P(strncmp), P(strncpy),
	{ "__platform_strlcpy", d_strlcpy }, { "_strlcpy", d_strlcpy }, { "__platform_memset_pattern4", d_pat4 }, { "__platform_memset_pattern16", d_pat16 },
	{ "_memset_pattern4", d_pat4 }, { "_memset_pattern16", d_pat16 }, { "___bzero", d_bzero }, { "_bzero", d_bzero },
	{ "___memcpy_chk", d_memcpy_chk }, { "___memmove_chk", d_memmove_chk }, { "___memset_chk", d_memset_chk },
	{ "_snprintf", d_snprintf }, { "_printf", d_printf }, { "_fprintf", d_fprintf }, { "_sscanf", d_sscanf }, { "_vsnprintf", d_vsnprintf },
	{ "____chkstk_darwin", d_chkstk }, { "___chkstk_darwin", d_chkstk }, { "___assert_rtn", d_assert }, { "___stack_chk_fail", d_stack_fail },
	{ "__Unwind_Resume", d_unwind_resume }, { "___sincos_stret", d_sincos }, { "___sincosf_stret", d_sincosf }, { "___cospif", d_cospif },
	{ "___exp10", d_exp10 }, { "___exp10f", d_exp10f }, { "__simd_log10_f4", d_log10_f4 }, { "__simd_log2_f4", d_log2_f4 },
	{ "___maskrune", d_maskrune }, { "___tolower", d_tolower }, { "___toupper", d_toupper },
	{ "_mach_absolute_time", d_mach_absolute_time }, { "_mach_timebase_info", d_mach_timebase_info },
	{ "_os_log_create", d_os_log_create }, { "_os_log_type_enabled", d_os_log_type_enabled }, { "__os_log_impl", d_os_log_impl },
	{ "_os_unfair_lock_lock", d_lock }, { "_os_unfair_lock_unlock", d_lock }, { "_os_unfair_lock_trylock", d_trylock },
	{ "_pthread_mutex_lock", d_lock }, { "_pthread_mutex_unlock", d_lock }, { "_dispatch_once", d_dispatch_once },
	{ "_posix_memalign", d_posix_memalign }, { "_getenv", d_getenv },
	{ "___stack_chk_guard", &stack_guard }, { "___stderrp", &d_stderr }, { "___stdoutp", &d_stdout }, { "___stdinp", &d_stdin },
	{ "_mach_task_self_", &task_self }, { "__os_log_default", &os_log_default }, { "__DefaultRuneLocale", &rune_locale },
	{ "__NSConcreteGlobalBlock", block_global }, { "__NSConcreteStackBlock", block_stack },
	{ 0, 0 } };
