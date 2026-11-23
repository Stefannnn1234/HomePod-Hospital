/* AudioToolbox pieces: the component registry the library registers its codecs with, and stubs. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "loader.h"
#include "atc.h"
const char *cf_cstr(const void *s);
component_t g_components[256]; int g_ncomponents;
static const char *cc4(uint32_t v, char *b) { b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v; b[4] = 0; return b; }
static void *AudioComponentRegister(const acd_t *d, const void *name, uint32_t version, void *factory) {
	char a[5], b[5], c[5];
	if (g_ncomponents == 256) return NULL;
	component_t *k = &g_components[g_ncomponents++]; k->desc = *d; k->factory = factory; k->name = cf_cstr(name);
	if (g_trace) fprintf(stderr, "  registered %s/%s/%s  %s\n", cc4(d->type, a), cc4(d->subtype, b), cc4(d->manufacturer, c), k->name);
	return k;
}
static int AudioComponentGetDescription(component_t *k, acd_t *out) { *out = k->desc; return 0; }
static component_t *AudioComponentInstanceGetComponent(instance_t *i) { return i->comp; }
static long zero(void) { return 0; }
int afmt_get(uint32_t id, uint32_t specSize, const void *spec, uint32_t *ioSize, void *out);
static int AudioFormatGetProperty(uint32_t id, uint32_t specSize, const void *spec, uint32_t *ioSize, void *out) {
	char a[5]; int r = afmt_get(id, specSize, spec, ioSize, out);
	if (g_trace || r == -1) { fprintf(stderr, "  AudioFormatGetProperty '%s' spec %u bytes:", cc4(id, a), specSize);
		for (uint32_t i = 0; i < specSize && i < 48; i++) fprintf(stderr, " %02x", ((const uint8_t *)spec)[i]);
		fprintf(stderr, " -> %d, size %u (from %p)\n", r, ioSize ? *ioSize : 0, __builtin_return_address(0)); }
	if (r == -1) exit(78);
	return r;
}
static long gestalt(void) { return 0; }
static void *cf_keys[40];
#define K(n) { "_" #n, &cf_keys[__COUNTER__] }
const shim_t shims_atc[] = {
	{ "_AudioComponentRegister", AudioComponentRegister }, { "_AudioComponentGetDescription", AudioComponentGetDescription },
	{ "_AudioComponentInstanceGetComponent", AudioComponentInstanceGetComponent }, { "_AudioComponentFindNext", zero },
	{ "_MGGetProductType", gestalt }, { "__Z32AudioBufferList_GetMetadataFramePK15AudioBufferList", zero }, { "_AudioFormatGetProperty", AudioFormatGetProperty }, { "_SecTaskCreateFromSelf", zero }, { "_SecTaskCopyValueForEntitlement", zero },
	{ "_IOServiceMatching", zero }, { "_IOServiceGetMatchingServices", zero }, { "_IOIteratorNext", zero }, { "_IOObjectRelease", zero }, { "_IOServiceOpen", zero }, { "_IOServiceClose", zero },
	{ 0, 0 } };
