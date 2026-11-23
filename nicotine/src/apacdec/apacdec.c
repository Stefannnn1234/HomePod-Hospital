/* apacdec: decoder helper process for APAC (the codec AirPlay uses for Dolby Atmos).
 *
 *   apacdec IMAGE CHANNELS [-v]
 *
 * IMAGE is the codec library extracted from the user's own HomePod firmware (nicotine/tools/extract_apac.py makes it).
 * Protocol on stdin/stdout, all little-endian:
 *   in :  u32 length, then that many bytes (one APAC packet, 1024 frames)
 *         length 0 = reset (after a seek or a gap)
 *   out:  u32 frames (0 if the packet could not be decoded), then frames * CHANNELS float32, interleaved
 * A line "ready CHANNELS\n" is written to stderr once the decoder is set up.
 * The process is disposable: on anything unexpected it exits and the receiver starts a new one. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <setjmp.h>
#include "loader.h"
#include "codec.h"
extern jmp_buf *g_throw_jmp; extern int g_throw_quiet;
static int rd(int fd, void *p, size_t n) { uint8_t *b = p; while (n) { ssize_t r = read(fd, b, n); if (r <= 0) return -1; b += r; n -= r; } return 0; }
static int wr(int fd, const void *p, size_t n) { const uint8_t *b = p; while (n) { ssize_t r = write(fd, b, n); if (r <= 0) return -1; b += r; n -= r; } return 0; }
#define MAXFR 4096
int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: apacdec IMAGE CHANNELS [-v]\n"); return 64; }
	int ch = atoi(argv[2]), verbose = argc > 3; char b[8]; jmp_buf jb;
	if (ch < 1 || ch > 16) return 64;
	if (apac_load(argv[1], 0)) return 66;
	((void (*)(void *))apac_sym("_RegisterExternalAudioCodecs"))(0);
	/* the configuration blob: what the sender's encoder produces for this channel count */
	static uint8_t cookie[1024]; uint32_t clen = sizeof cookie;
	asbd_t pcm = { 48000, FCC("lpcm"), 0x9, 4 * ch, 1, 4 * ch, ch, 32, 0 }, apac = { 48000, FCC("apac"), 0, 0, 1024, 0, ch, 0, 0 };
	g_throw_jmp = &jb;
	if (setjmp(jb)) { fprintf(stderr, "apacdec: set-up failed\n"); return 70; }
	codec_t enc, dec; uint32_t zero = 0; int r;
	if ((r = codec_open(&enc, FCC("aenc"), FCC("apac")))) { fprintf(stderr, "apacdec: no encoder (%d)\n", r); return 70; }
	enc.SetProperty(enc.p, FCC("cdrc"), 4, &zero);
	if ((r = enc.Initialize(enc.p, &pcm, &apac, NULL, 0)) || (r = enc.GetProperty(enc.p, FCC("kuki"), &clen, cookie))) { fprintf(stderr, "apacdec: configuration: %s\n", fcc(r, b)); return 70; }
	enc.Uninitialize(enc.p);
	if ((r = codec_open(&dec, FCC("adec"), FCC("apac"))) || (r = dec.Initialize(dec.p, &apac, &pcm, cookie, clen))) { fprintf(stderr, "apacdec: decoder: %s\n", fcc(r, b)); return 70; }
	fprintf(stderr, "ready %d\n", ch);
	static uint8_t in[1 << 17]; float *out = malloc(sizeof(float) * ch * MAXFR); uint32_t len; long n = 0, bad = 0; int run = 0;
	g_throw_quiet = !verbose;
	while (rd(0, &len, 4) == 0) {
		uint32_t frames = 0;
		if (len > sizeof in) return 65;
		if (len && rd(0, in, len)) break;
		if (setjmp(jb)) {                                  /* the codec rejected this packet */
			bad++; frames = 0;
			if (++run > 50) { fprintf(stderr, "apacdec: too many bad packets in a row\n"); return 71; }
			g_throw_jmp = NULL; dec.Reset(dec.p); g_throw_jmp = &jb;
		} else if (len == 0) {
			dec.Reset(dec.p); continue;                       /* no reply to a reset */
		} else {
			uint32_t bytes = len, pk = 1, ob = sizeof(float) * ch * MAXFR, op = MAXFR, st = 0; pktdesc_t d = { 0, 0, len };
			r = dec.AppendInputData(dec.p, in, &bytes, &pk, &d);
			if (!r) r = dec.ProduceOutputPackets(dec.p, out, &ob, &op, NULL, &st);
			if (!r && op && op <= MAXFR) { frames = op; run = 0; } else { bad++; if (verbose) fprintf(stderr, "apacdec: packet %ld: %s\n", n, fcc(r, b)); }
		}
		n++;
		if (wr(1, &frames, 4) || (frames && wr(1, out, sizeof(float) * ch * frames))) break;
	}
	if (verbose) fprintf(stderr, "apacdec: %ld packets, %ld bad\n", n, bad);
	return 0;
}
