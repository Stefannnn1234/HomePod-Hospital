/* Loads the extracted AudioCodecs image (see nicotine/tools/extract_apac.py) at its original addresses and connects
 * every outside symbol to a stand-in. Linux aarch64. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include "loader.h"
static int errno_is_exist(void) { if (errno == EEXIST) return 1; perror("mmap"); exit(2); }
int g_trace;
typedef struct { uint64_t vmaddr, size; uint32_t prot, fileoff; } seg_t;
typedef struct { uint64_t addr; uint32_t import; int32_t addend; } fix_t;
typedef struct { uint64_t addr; uint32_t import, pad; } isl_t;
typedef struct { uint64_t addr; uint32_t name, pad; } ent_t;
static const char *strtab; static ent_t *entries; static uint32_t nent;
static const char **impname; static uint32_t nimp;
#define PG 0x1000UL
static void map_range(uint64_t lo, uint64_t hi) {          /* idempotent page mapping, RWX for simplicity */
	for (uint64_t p = lo & ~(PG - 1); p < hi; p += PG) {
		void *r = mmap((void *)p, PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
		if (r == MAP_FAILED && errno_is_exist()) continue;
	}
}

/* one small code stub per unimplemented import: it reports the name and stops */
void unimpl_c(uint64_t idx, uint64_t lr) {
	fprintf(stderr, "\n*** not implemented: %s (called from %#lx)\n", idx < nimp ? impname[idx] : "?", (unsigned long)lr);
	exit(70);
}
__asm__(".text\n.global unimpl_entry\nunimpl_entry:\n mov x0, x16\n mov x1, x30\n b unimpl_c\n");
extern void unimpl_entry(void);
static void *make_unimpl(uint32_t idx) {
	static uint32_t *page; static int used;
	if (!page || used + 6 > 1024) { page = mmap(NULL, PG, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); used = 0; }
	uint32_t *c = page + used; used += 6;
	c[0] = 0xD2800010 | ((idx & 0xFFFF) << 5);          /* movz x16, #idx */
	c[1] = 0x58000071;                                   /* ldr x17, #12 */
	c[2] = 0xD61F0220;                                   /* br x17 */
	c[3] = 0xD503201F;
	*(uint64_t *)(c + 4) = (uint64_t)unimpl_entry;
	__builtin___clear_cache((char *)c, (char *)(c + 6));
	return c;
}
static void *find_shim(const char *n) {
	const shim_t *tabs[] = { shims_base, shims_cf, shims_cxx, shims_vdsp, shims_atc, shims_str };
	for (unsigned t = 0; t < sizeof tabs / sizeof *tabs; t++)
		for (const shim_t *s = tabs[t]; s->name; s++)
			if (!strcmp(s->name, n)) return s->addr;
	return NULL;
}
void *apac_sym(const char *name) {
	for (uint32_t i = 0; i < nent; i++) if (!strcmp(strtab + entries[i].name, name)) return (void *)entries[i].addr;
	return NULL;
}
int apac_load(const char *path, int verbose) {
	int fd = open(path, O_RDONLY); if (fd < 0) { perror(path); return -1; }
	off_t len = lseek(fd, 0, SEEK_END);
	uint8_t *f = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
	if (f == MAP_FAILED || memcmp(f, "NICAPAC1", 8)) { fprintf(stderr, "%s: not an extracted image\n", path); return -1; }
	uint32_t *h = (uint32_t *)(f + 8); uint32_t nseg = h[0], nfix = h[2], nisl = h[3]; nimp = h[1]; nent = h[4];
	seg_t *seg = (seg_t *)(f + 28); uint32_t *imp = (uint32_t *)(seg + nseg);
	fix_t *fix = (fix_t *)(imp + nimp); isl_t *isl = (isl_t *)(fix + nfix); entries = (ent_t *)(isl + nisl);
	uint32_t *strsz = (uint32_t *)(entries + nent); strtab = (const char *)(strsz + 1);
	uint8_t *blob = (uint8_t *)strtab + *strsz;
	for (uint32_t i = 0; i < nseg; i++) {
		map_range(seg[i].vmaddr, seg[i].vmaddr + seg[i].size);
		memcpy((void *)seg[i].vmaddr, blob + seg[i].fileoff, seg[i].size);
	}
	impname = malloc(nimp * sizeof *impname); void **target = malloc(nimp * sizeof *target); int missing = 0;
	for (uint32_t i = 0; i < nimp; i++) {
		impname[i] = strtab + imp[i]; target[i] = find_shim(impname[i]);
		if (!target[i]) { target[i] = make_unimpl(i); missing++; if (verbose > 1) fprintf(stderr, "  no stand-in: %s\n", impname[i]); }
	}
	for (uint32_t i = 0; i < nfix; i++) {
		map_range(fix[i].addr, fix[i].addr + 8);
		*(uint64_t *)fix[i].addr = (uint64_t)target[fix[i].import] + fix[i].addend;
	}
	/* direct branch targets: adrp x16, table ; ldr x16, [x16, #off] ; br x16 */
	uint64_t *table = mmap((void *)0x1b0000000UL, PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
	if (table == MAP_FAILED || nisl > PG / 8) { perror("table"); return -1; }
	for (uint32_t i = 0; i < nisl; i++) {
		uint64_t a = isl[i].addr; map_range(a, a + 12);
		table[i] = (uint64_t)target[isl[i].import];
		int64_t pages = ((int64_t)((uint64_t)table & ~(PG - 1)) - (int64_t)(a & ~(PG - 1))) >> 12;
		uint32_t *c = (uint32_t *)a;
		c[0] = 0x90000010 | ((uint32_t)(pages & 3) << 29) | ((uint32_t)((pages >> 2) & 0x7FFFF) << 5);
		c[1] = 0xF9400210 | ((uint32_t)i << 10);
		c[2] = 0xD61F0200;
	}
	for (uint32_t i = 0; i < nseg; i++) __builtin___clear_cache((char *)seg[i].vmaddr, (char *)(seg[i].vmaddr + seg[i].size));
	if (verbose) fprintf(stderr, "loaded: %u segments, %u outside symbols (%d without a stand-in yet), %u pointer fixes, %u branch targets\n", nseg, nimp, missing, nfix, nisl);
	return 0;
}

/* crash report: where, and the chain of return addresses (frame pointers) */
#include <signal.h>
#include <ucontext.h>
static void on_fault(int sig, siginfo_t *si, void *uc_) {
	ucontext_t *uc = uc_; mcontext_t *m = &uc->uc_mcontext;
	fprintf(stderr, "\n*** signal %d at pc %#llx, address %p, lr %#llx\nBT", sig, (unsigned long long)m->pc, si->si_addr, (unsigned long long)m->regs[30]);
	fprintf(stderr, " %#llx %#llx", (unsigned long long)m->pc, (unsigned long long)m->regs[30]);
	uint64_t *fp = (uint64_t *)m->regs[29];
	for (int i = 0; i < 24 && fp && !((uint64_t)fp & 7) && (uint64_t)fp > 0x10000; i++) { fprintf(stderr, " %#llx", (unsigned long long)fp[1]); if ((uint64_t *)fp[0] <= fp) break; fp = (uint64_t *)fp[0]; }
	fprintf(stderr, "\nREGS"); for (int i = 0; i < 9; i++) fprintf(stderr, " x%d=%#llx", i, (unsigned long long)m->regs[i]);
	fprintf(stderr, "\n"); _exit(80);
}
__attribute__((constructor)) static void install_fault(void) {
	struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = on_fault; sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, 0); sigaction(SIGBUS, &sa, 0); sigaction(SIGILL, &sa, 0);
}
