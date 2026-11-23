#pragma once
#include <stdint.h>
#include "atc.h"
typedef struct { double rate; uint32_t id, flags, bytesPerPacket, framesPerPacket, bytesPerFrame, channels, bits, reserved; } asbd_t;
typedef struct { int64_t start; uint32_t varFrames, size; } pktdesc_t;
typedef struct {
	plugin_t *p; instance_t inst;
	int (*GetPropertyInfo)(void *, uint32_t id, uint32_t *size, uint8_t *writable);
	int (*GetProperty)(void *, uint32_t id, uint32_t *size, void *data);
	int (*SetProperty)(void *, uint32_t id, uint32_t size, const void *data);
	int (*Initialize)(void *, const asbd_t *in, const asbd_t *out, const void *cookie, uint32_t cookieSize);
	int (*Uninitialize)(void *);
	int (*AppendInputData)(void *, const void *data, uint32_t *bytes, uint32_t *packets, const pktdesc_t *desc);
	int (*ProduceOutputPackets)(void *, void *out, uint32_t *bytes, uint32_t *packets, pktdesc_t *desc, uint32_t *status);
	int (*Reset)(void *);
} codec_t;
int codec_open(codec_t *c, uint32_t type, uint32_t subtype);
#define FCC(s) ((uint32_t)(s[0] << 24 | s[1] << 16 | s[2] << 8 | s[3]))
static inline const char *fcc(int32_t v, char *b) { unsigned char *u = (unsigned char *)b; u[0] = v >> 24; u[1] = v >> 16; u[2] = v >> 8; u[3] = v; b[4] = 0;
	for (int i = 0; i < 4; i++) if (u[i] < 32 || u[i] > 126) { static char n[16]; __builtin_snprintf(n, sizeof n, "%d", v); return n; } return b; }
