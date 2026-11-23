#pragma once
#include <stdint.h>
#include <stddef.h>
typedef struct { const char *name; void *addr; } shim_t;
extern const shim_t shims_base[], shims_cf[], shims_cxx[], shims_vdsp[], shims_atc[], shims_str[];
void *apac_sym(const char *name);          /* address of a function inside the loaded library */
int apac_load(const char *path, int verbose);
void unimpl_note(const char *what);
extern int g_trace;
