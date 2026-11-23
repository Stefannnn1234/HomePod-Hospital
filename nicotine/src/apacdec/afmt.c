/* the few AudioFormat queries the codecs make (channel layouts) */
#include <stdint.h>
#include <string.h>
#include "afmt_layouts.h"
typedef struct { uint32_t tag, bitmap, n; chdesc_t d[]; } layout_t;
#define FCC(s) ((uint32_t)(s[0] << 24 | s[1] << 16 | s[2] << 8 | s[3]))
static int by_tag(uint32_t tag) { for (unsigned i = 0; i < sizeof layout_tags / sizeof *layout_tags; i++) if (layout_tags[i].tag == tag) return i; return -1; }
static int popcount(uint32_t v) { return __builtin_popcount(v); }
int afmt_get(uint32_t id, uint32_t specSize, const void *spec, uint32_t *ioSize, void *out) {
	if (id == FCC("cmpl") && specSize == 4) {                     /* ChannelLayoutForTag */
		uint32_t tag = *(const uint32_t *)spec; int i = by_tag(tag);
		if (i < 0) { uint32_t hi = tag >> 16, n = tag & 0xFFFF;      /* DiscreteInOrder / Unknown: n channels without positions */
			if (hi != 147 && hi != 0xFFFF) return -1;
			if (!out) { *ioSize = 12 + 20 * n; return 0; }
			layout_t *l = out; memset(l, 0, 12 + 20 * n); l->tag = tag; l->n = n; for (uint32_t k = 0; k < n; k++) l->d[k].label = hi == 147 ? 0x10000 + k : 0xFFFFFFFF; *ioSize = 12 + 20 * n; return 0; }
		uint32_t need = 12 + 20 * layout_tags[i].n;
		if (!out) { *ioSize = need; return 0; }
		if (*ioSize < need) return 0x2173697A;                      /* '!siz' */
		layout_t *l = out; l->tag = tag; l->bitmap = 0; l->n = layout_tags[i].n; memcpy(l->d, &layout_desc[layout_tags[i].first], 20 * l->n); *ioSize = need; return 0;
	}
	if (id == FCC("nchm") && specSize >= 12) {                    /* NumberOfChannelsForLayout */
		const layout_t *l = spec; uint32_t n = l->tag == 0 ? l->n : l->tag == 0x10000 ? (uint32_t)popcount(l->bitmap) : (l->tag & 0xFFFF);
		if (out) *(uint32_t *)out = n; *ioSize = 4; return 0;
	}
	return -1;
}
