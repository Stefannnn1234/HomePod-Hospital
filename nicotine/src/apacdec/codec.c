#include <stdio.h>
#include <string.h>
#include "loader.h"
#include "codec.h"
int codec_open(codec_t *c, uint32_t type, uint32_t subtype) {
	memset(c, 0, sizeof *c);
	for (int i = 0; i < g_ncomponents; i++) {
		component_t *k = &g_components[i];
		if (k->desc.type != type || k->desc.subtype != subtype) continue;
		c->p = ((plugin_t *(*)(const acd_t *))k->factory)(&k->desc);
		if (!c->p) return -1;
		c->inst.comp = k; c->inst.plugin = c->p;
		int r = c->p->Open(c->p, &c->inst);
		if (r) { fprintf(stderr, "Open failed: %d\n", r); return r; }
		c->GetPropertyInfo = c->p->Lookup(1); c->GetProperty = c->p->Lookup(2); c->SetProperty = c->p->Lookup(3); c->Initialize = c->p->Lookup(4);
		c->Uninitialize = c->p->Lookup(5); c->AppendInputData = c->p->Lookup(6); c->ProduceOutputPackets = c->p->Lookup(7); c->Reset = c->p->Lookup(8);
		return 0;
	}
	return -2;
}
