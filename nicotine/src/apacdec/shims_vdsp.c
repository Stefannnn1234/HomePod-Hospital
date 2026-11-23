/* Stand-ins for the Accelerate (vDSP / vForce / BLAS) functions the library uses, written from the
 * documented behaviour of each function. Plain C for now; speed comes later. */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "loader.h"
typedef unsigned long L; typedef long S;
typedef struct { float *re, *im; } zf;
#define V2(name, expr) static void name(const float *A, S IA, const float *B, S IB, float *C, S IC, L N) { for (L n = 0; n < N; n++) { float a = A[n * IA], b = B[n * IB]; C[n * IC] = (expr); } }
V2(vadd, a + b) V2(vsub, b - a) V2(vmul, a * b) V2(vdiv, b / a) V2(vmax, a > b ? a : b) V2(vmin, a < b ? a : b) V2(vmaxmg, fabsf(a) > fabsf(b) ? fabsf(a) : fabsf(b)) V2(vdist, sqrtf(a * a + b * b))
static void vaddD(const double *A, S IA, const double *B, S IB, double *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = A[n * IA] + B[n * IB]; }
#define VS(name, expr) static void name(const float *A, S IA, const float *B, float *C, S IC, L N) { float b = *B; for (L n = 0; n < N; n++) { float a = A[n * IA]; C[n * IC] = (expr); } }
VS(vsmul, a * b) VS(vsadd, a + b) VS(vsdiv, a / b) VS(vthr, a >= b ? a : b) VS(vthres, a >= b ? a : 0.0f)
static void vsmulD(const double *A, S IA, const double *B, double *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = A[n * IA] * *B; }
static void svdiv(const float *A, const float *B, S IB, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = *A / B[n * IB]; }
#define V1(name, expr) static void name(const float *A, S IA, float *C, S IC, L N) { for (L n = 0; n < N; n++) { float a = A[n * IA]; C[n * IC] = (expr); } }
V1(vabs, fabsf(a)) V1(vneg, -a) V1(vsq, a * a) V1(vssq, a * fabsf(a))
static void vsma(const float *A, S IA, const float *B, const float *C, S IC, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = A[n * IA] * *B + C[n * IC]; }
static void vsmsa(const float *A, S IA, const float *B, const float *C, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = A[n * IA] * *B + *C; }
static void vsmsb(const float *A, S IA, const float *B, const float *C, S IC, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = A[n * IA] * *B - C[n * IC]; }
static void vsmsma(const float *A, S IA, const float *B, const float *C, S IC, const float *D, float *E, S IE, L N) { for (L n = 0; n < N; n++) E[n * IE] = A[n * IA] * *B + C[n * IC] * *D; }
static void vma(const float *A, S IA, const float *B, S IB, const float *C, S IC, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = A[n * IA] * B[n * IB] + C[n * IC]; }
static void vmsa(const float *A, S IA, const float *B, S IB, const float *C, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = A[n * IA] * B[n * IB] + *C; }
static void vmsb(const float *A, S IA, const float *B, S IB, const float *C, S IC, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = A[n * IA] * B[n * IB] - C[n * IC]; }
static void vmma(const float *A, S IA, const float *B, S IB, const float *C, S IC, const float *D, S ID, float *E, S IE, L N) { for (L n = 0; n < N; n++) E[n * IE] = A[n * IA] * B[n * IB] + C[n * IC] * D[n * ID]; }
static void vasm(const float *A, S IA, const float *B, S IB, const float *C, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = (A[n * IA] + B[n * IB]) * *C; }
static void vsbsm(const float *A, S IA, const float *B, S IB, const float *C, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = (A[n * IA] - B[n * IB]) * *C; }
static void vintb(const float *A, S IA, const float *B, S IB, const float *C, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = A[n * IA] + *C * (B[n * IB] - A[n * IA]); }
static void vclr(float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = 0; }
static void vfill(const float *A, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = *A; }
static void vfillD(const double *A, double *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = *A; }
static void vfilli(const int *A, int *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = *A; }
static void vsaddi(const int *A, S IA, const int *B, int *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = A[n * IA] + *B; }
static void vclip(const float *A, S IA, const float *B, const float *C, float *D, S ID, L N) { for (L n = 0; n < N; n++) { float a = A[n * IA]; D[n * ID] = a < *B ? *B : a > *C ? *C : a; } }
static void vthrsc(const float *A, S IA, const float *B, const float *C, float *D, S ID, L N) { for (L n = 0; n < N; n++) D[n * ID] = A[n * IA] >= *B ? *C : -*C; }
static void maxv(const float *A, S IA, float *C, L N) { float m = -INFINITY; for (L n = 0; n < N; n++) if (A[n * IA] > m) m = A[n * IA]; *C = m; }
static void minv(const float *A, S IA, float *C, L N) { float m = INFINITY; for (L n = 0; n < N; n++) if (A[n * IA] < m) m = A[n * IA]; *C = m; }
static void maxmgv(const float *A, S IA, float *C, L N) { float m = 0; for (L n = 0; n < N; n++) if (fabsf(A[n * IA]) > m) m = fabsf(A[n * IA]); *C = m; }
static void maxvi(const float *A, S IA, float *C, L *I, L N) { float m = -INFINITY; L k = 0; for (L n = 0; n < N; n++) if (A[n * IA] > m) { m = A[n * IA]; k = n * IA; } *C = m; *I = k; }
static void minvi(const float *A, S IA, float *C, L *I, L N) { float m = INFINITY; L k = 0; for (L n = 0; n < N; n++) if (A[n * IA] < m) { m = A[n * IA]; k = n * IA; } *C = m; *I = k; }
static void maxmgvi(const float *A, S IA, float *C, L *I, L N) { float m = -1; L k = 0; for (L n = 0; n < N; n++) if (fabsf(A[n * IA]) > m) { m = fabsf(A[n * IA]); k = n * IA; } *C = N ? m : 0; *I = k; }
static void minmgvi(const float *A, S IA, float *C, L *I, L N) { float m = INFINITY; L k = 0; for (L n = 0; n < N; n++) if (fabsf(A[n * IA]) < m) { m = fabsf(A[n * IA]); k = n * IA; } *C = m; *I = k; }
static void meanv(const float *A, S IA, float *C, L N) { double s = 0; for (L n = 0; n < N; n++) s += A[n * IA]; *C = N ? (float)(s / N) : NAN; }
static void sve(const float *A, S IA, float *C, L N) { float s = 0; for (L n = 0; n < N; n++) s += A[n * IA]; *C = s; }
static void svemg(const float *A, S IA, float *C, L N) { float s = 0; for (L n = 0; n < N; n++) s += fabsf(A[n * IA]); *C = s; }
static void svesq(const float *A, S IA, float *C, L N) { float s = 0; for (L n = 0; n < N; n++) s += A[n * IA] * A[n * IA]; *C = s; }
static void rmsqv(const float *A, S IA, float *C, L N) { double s = 0; for (L n = 0; n < N; n++) s += (double)A[n * IA] * A[n * IA]; *C = (float)sqrt(s / N); }
static void dotpr(const float *A, S IA, const float *B, S IB, float *C, L N) { float s = 0; for (L n = 0; n < N; n++) s += A[n * IA] * B[n * IB]; *C = s; }
static void dotprD(const double *A, S IA, const double *B, S IB, double *C, L N) { double s = 0; for (L n = 0; n < N; n++) s += A[n * IA] * B[n * IB]; *C = s; }
static void dotpr2(const float *A0, S IA0, const float *A1, S IA1, const float *B, S IB, float *C0, float *C1, L N) { float s0 = 0, s1 = 0; for (L n = 0; n < N; n++) { s0 += A0[n * IA0] * B[n * IB]; s1 += A1[n * IA1] * B[n * IB]; } *C0 = s0; *C1 = s1; }
static void distancesq(const float *A, S IA, const float *B, S IB, float *C, L N) { float s = 0; for (L n = 0; n < N; n++) { float d = A[n * IA] - B[n * IB]; s += d * d; } *C = s; }
static void vramp(const float *A, const float *B, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = *A + n * *B; }
static void vrampmul(const float *I, S IS, float *Start, const float *Step, float *O, S OS, L N) { float g = *Start; for (L n = 0; n < N; n++) { O[n * OS] = g * I[n * IS]; g += *Step; } *Start = g; }
static void vrampmuladd(const float *I, S IS, float *Start, const float *Step, float *O, S OS, L N) { float g = *Start; for (L n = 0; n < N; n++) { O[n * OS] += g * I[n * IS]; g += *Step; } *Start = g; }
static void vgenD(const double *A, const double *B, double *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = N > 1 ? *A + (*B - *A) * n / (double)(N - 1) : *A; }
static void vrvrs(float *C, S IC, L N) { for (L n = 0; n < N / 2; n++) { float t = C[n * IC]; C[n * IC] = C[(N - 1 - n) * IC]; C[(N - 1 - n) * IC] = t; } }
static void vswap(float *A, S IA, float *B, S IB, L N) { for (L n = 0; n < N; n++) { float t = A[n * IA]; A[n * IA] = B[n * IB]; B[n * IB] = t; } }
static int cmp_up(const void *a, const void *b) { float x = *(const float *)a, y = *(const float *)b; return x < y ? -1 : x > y; }
static int cmp_dn(const void *a, const void *b) { return -cmp_up(a, b); }
static void vsort(float *C, L N, int order) { qsort(C, N, sizeof *C, order >= 0 ? cmp_up : cmp_dn); }
static void vsorti(const float *C, L *I, L *tmp, L N, int order) {            /* stable insertion sort of the index list */
	for (L i = 1; i < N; i++) { L k = I[i]; S j = (S)i - 1; while (j >= 0 && (order >= 0 ? C[I[j]] > C[k] : C[I[j]] < C[k])) { I[j + 1] = I[j]; j--; } I[j + 1] = k; }
}
static void vdbcon(const float *A, S IA, const float *B, float *C, S IC, L N, unsigned F) { float al = F == 1 ? 20.0f : 10.0f; for (L n = 0; n < N; n++) C[n * IC] = al * log10f(A[n * IA] / *B); }
static void vdpsp(const double *A, S IA, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = (float)A[n * IA]; }
static void vspdp(const float *A, S IA, double *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = A[n * IA]; }
static void vfix32(const float *A, S IA, int *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = (int)A[n * IA]; }
static void vfixr16(const float *A, S IA, short *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = (short)lrintf(A[n * IA]); }
static void vflt16(const short *A, S IA, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = A[n * IA]; }
static void vflt32(const int *A, S IA, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = (float)A[n * IA]; }
static void vswmax(const float *A, S IA, float *C, S IC, L N, L W) { for (L n = 0; n < N; n++) { float m = A[n * IA]; for (L w = 1; w < W; w++) if (A[(n + w) * IA] > m) m = A[(n + w) * IA]; C[n * IC] = m; } }
static void mmov(const float *A, float *C, L M, L N, L TA, L TC) { for (L r = 0; r < N; r++) memmove(C + r * TC, A + r * TA, M * sizeof *A); }
static void mmul(const float *A, S IA, const float *B, S IB, float *C, S IC, L M, L N, L P) {
	for (L m = 0; m < M; m++) for (L n = 0; n < N; n++) { float s = 0; for (L p = 0; p < P; p++) s += A[(m * P + p) * IA] * B[(p * N + n) * IB]; C[(m * N + n) * IC] = s; }
}
static void mtrans(const float *A, S IA, float *C, S IC, L M, L N) { for (L m = 0; m < M; m++) for (L n = 0; n < N; n++) C[(m * N + n) * IC] = A[(n * M + m) * IA]; }
static void hann_window(float *C, L N, int flag) {
	L cnt = (flag & 1) ? (N + 1) / 2 : N; double k = (flag & 2) ? 0.8164965809277261 : 0.5;
	for (L n = 0; n < cnt; n++) C[n] = (float)(k * (1.0 - cos(2.0 * M_PI * n / N)));
}
static void conv(const float *A, S IA, const float *F, S IF, float *C, S IC, L N, L P) { for (L n = 0; n < N; n++) { float s = 0; for (L p = 0; p < P; p++) s += A[(n + p) * IA] * F[(S)p * IF]; C[n * IC] = s; } }
static void desamp(const float *A, S DF, const float *F, float *C, L N, L P) { for (L n = 0; n < N; n++) { float s = 0; for (L p = 0; p < P; p++) s += A[n * DF + p] * F[p]; C[n] = s; } }
static void deq22(const float *A, S IA, const float *B, float *C, S IC, L N) {
	for (L n = 2; n < N + 2; n++) C[n * IC] = A[n * IA] * B[0] + A[(n - 1) * IA] * B[1] + A[(n - 2) * IA] * B[2] - C[(n - 1) * IC] * B[3] - C[(n - 2) * IC] * B[4];
}
static void ctoz(const float *C, S IC, const zf *Z, S IZ, L N) { for (L n = 0; n < N; n++) { Z->re[n * IZ] = C[n * IC]; Z->im[n * IZ] = C[n * IC + 1]; } }
static void ztoc(const zf *Z, S IZ, float *C, S IC, L N) { for (L n = 0; n < N; n++) { C[n * IC] = Z->re[n * IZ]; C[n * IC + 1] = Z->im[n * IZ]; } }
static void zvabs(const zf *A, S IA, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = hypotf(A->re[n * IA], A->im[n * IA]); }
static void zvmags(const zf *A, S IA, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = A->re[n * IA] * A->re[n * IA] + A->im[n * IA] * A->im[n * IA]; }
static void zvphas(const zf *A, S IA, float *C, S IC, L N) { for (L n = 0; n < N; n++) C[n * IC] = atan2f(A->im[n * IA], A->re[n * IA]); }
static void zvadd(const zf *A, S IA, const zf *B, S IB, const zf *C, S IC, L N) { for (L n = 0; n < N; n++) { C->re[n * IC] = A->re[n * IA] + B->re[n * IB]; C->im[n * IC] = A->im[n * IA] + B->im[n * IB]; } }
static void zvmul(const zf *A, S IA, const zf *B, S IB, const zf *C, S IC, L N, int conj) {
	for (L n = 0; n < N; n++) { float ar = A->re[n * IA], ai = conj < 0 ? -A->im[n * IA] : A->im[n * IA], br = B->re[n * IB], bi = B->im[n * IB]; C->re[n * IC] = ar * br - ai * bi; C->im[n * IC] = ar * bi + ai * br; }
}
static void zvcmul(const zf *A, S IA, const zf *B, S IB, const zf *C, S IC, L N) { zvmul(A, IA, B, IB, C, IC, N, -1); }
static void zvconj(const zf *A, S IA, const zf *C, S IC, L N) { for (L n = 0; n < N; n++) { C->re[n * IC] = A->re[n * IA]; C->im[n * IC] = -A->im[n * IA]; } }
static void zvmov(const zf *A, S IA, const zf *C, S IC, L N) { for (L n = 0; n < N; n++) { C->re[n * IC] = A->re[n * IA]; C->im[n * IC] = A->im[n * IA]; } }
static void zvzsml(const zf *A, S IA, const zf *B, const zf *C, S IC, L N) { float br = *B->re, bi = *B->im; for (L n = 0; n < N; n++) { float ar = A->re[n * IA], ai = A->im[n * IA]; C->re[n * IC] = ar * br - ai * bi; C->im[n * IC] = ar * bi + ai * br; } }
static void zrvmul(const zf *A, S IA, const float *B, S IB, const zf *C, S IC, L N) { for (L n = 0; n < N; n++) { float b = B[n * IB]; C->re[n * IC] = A->re[n * IA] * b; C->im[n * IC] = A->im[n * IA] * b; } }
static void zvcma(const zf *A, S IA, const zf *B, S IB, const zf *C, S IC, const zf *D, S ID, L N) {
	for (L n = 0; n < N; n++) { float ar = A->re[n * IA], ai = -A->im[n * IA], br = B->re[n * IB], bi = B->im[n * IB]; float r = ar * br - ai * bi + C->re[n * IC], i = ar * bi + ai * br + C->im[n * IC]; D->re[n * ID] = r; D->im[n * ID] = i; }
}
static void rect(const float *A, S IA, float *C, S IC, L N) { for (L n = 0; n < N; n++) { float r = A[n * IA], t = A[n * IA + 1]; C[n * IC] = r * cosf(t); C[n * IC + 1] = r * sinf(t); } }

/* ---- transforms: one general complex DFT (radix 2 when possible, direct otherwise) ---- */
typedef struct { L n; int dir, kind, type; double *cs, *sn; } dft_t;      /* kind: 0 complex, 1 real, 2 dct */
static void cdft(L n, const double *cs, const double *sn, int sign, double *re, double *im) {      /* in place; sign -1 forward */
	if ((n & (n - 1)) == 0) {
		for (L i = 1, j = 0; i < n; i++) { L bit = n >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
		for (L len = 2; len <= n; len <<= 1) { L step = n / len;
			for (L i = 0; i < n; i += len) for (L k = 0; k < len / 2; k++) {
				double wr = cs[k * step], wi = sign * sn[k * step], ur = re[i + k], ui = im[i + k], vr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi, vi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr;
				re[i + k] = ur + vr; im[i + k] = ui + vi; re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi; } }
		return;
	}
	double *tr = malloc(2 * n * sizeof *tr), *ti = tr + n;
	for (L k = 0; k < n; k++) { double sr = 0, si = 0; for (L j = 0; j < n; j++) { L m = (k * j) % n; double wr = cs[m], wi = sign * sn[m]; sr += re[j] * wr - im[j] * wi; si += re[j] * wi + im[j] * wr; } tr[k] = sr; ti[k] = si; }
	memcpy(re, tr, n * sizeof *re); memcpy(im, ti, n * sizeof *im); free(tr);
}
static dft_t *dft_new(L n, int dir, int kind, int type) { dft_t *d = calloc(1, sizeof *d); d->n = n; d->dir = dir; d->kind = kind; d->type = type; d->cs = malloc(2 * n * sizeof(double)); d->sn = d->cs + n;
	for (L k = 0; k < n; k++) { d->cs[k] = cos(2 * M_PI * k / n); d->sn[k] = sin(2 * M_PI * k / n); } return d; }
static dft_t *DFT_zop_Create(dft_t *prev, L n, int dir) { return dft_new(n, dir, 0, 0); }
static dft_t *DFT_zrop_Create(dft_t *prev, L n, int dir) { return dft_new(n, dir, 1, 0); }
static void DFT_Destroy(dft_t *d) { if (d) { free(d->cs); free(d); } }
/* packed real transform (same data layout as vDSP_fft_zrip): forward gives twice the mathematical result */
static void real_packed(dft_t *d, int dir, const float *ir, const float *ii, float *or_, float *oi) {
	L n = d->n, h = n / 2; double *re = malloc(2 * n * sizeof *re), *im = re + n;
	if (dir > 0) {
		for (L k = 0; k < h; k++) { re[2 * k] = ir[k]; re[2 * k + 1] = ii[k]; im[2 * k] = im[2 * k + 1] = 0; }
		cdft(n, d->cs, d->sn, -1, re, im);
		for (L k = 1; k < h; k++) { or_[k] = (float)(2 * re[k]); oi[k] = (float)(2 * im[k]); }
		or_[0] = (float)(2 * re[0]); oi[0] = (float)(2 * re[h]);
	} else {
		re[0] = ir[0]; im[0] = 0; re[h] = ii[0]; im[h] = 0;
		for (L k = 1; k < h; k++) { re[k] = ir[k]; im[k] = ii[k]; re[n - k] = ir[k]; im[n - k] = -ii[k]; }
		cdft(n, d->cs, d->sn, +1, re, im);
		for (L k = 0; k < h; k++) { or_[k] = (float)re[2 * k]; oi[k] = (float)re[2 * k + 1]; }
	}
	free(re);
}
static void DFT_Execute(dft_t *d, const float *ir, const float *ii, float *or_, float *oi) {
	if (d->kind == 1) { real_packed(d, d->dir, ir, ii, or_, oi); return; }
	L n = d->n; double *re = malloc(2 * n * sizeof *re), *im = re + n;
	for (L k = 0; k < n; k++) { re[k] = ir[k]; im[k] = ii[k]; }
	cdft(n, d->cs, d->sn, d->dir > 0 ? -1 : +1, re, im);
	for (L k = 0; k < n; k++) { or_[k] = (float)re[k]; oi[k] = (float)im[k]; }
	free(re);
}
static dft_t *create_fftsetup(L log2n, int radix) { return dft_new(1UL << log2n, 0, 1, 0); }
static void fft_zrip(dft_t *setup, const zf *C, S IC, L log2n, int dir) {
	dft_t d = { 1UL << log2n, dir, 1, 0, 0, 0 }; d.cs = malloc(2 * d.n * sizeof(double)); d.sn = d.cs + d.n;
	for (L k = 0; k < d.n; k++) { d.cs[k] = cos(2 * M_PI * k / d.n); d.sn[k] = sin(2 * M_PI * k / d.n); }
	real_packed(&d, dir, C->re, C->im, C->re, C->im); free(d.cs);
}
static dft_t *DCT_Create(dft_t *prev, L n, int type) { return dft_new(n, 1, 2, type); }
static void DCT_Execute(dft_t *d, const float *in, float *out) {             /* direct evaluation of the documented sums */
	L n = d->n; float *t = malloc(n * sizeof *t);
	for (L k = 0; k < n; k++) { double s = 0;
		if (d->type == 2) for (L j = 0; j < n; j++) s += in[j] * cos(M_PI * (j + 0.5) * k / n);
		else if (d->type == 3) { s = in[0] / 2; for (L j = 1; j < n; j++) s += in[j] * cos(M_PI * j * (k + 0.5) / n); }
		else for (L j = 0; j < n; j++) s += in[j] * cos(M_PI * (j + 0.5) * (k + 0.5) / n);
		t[k] = (float)s; }
	memcpy(out, t, n * sizeof *t); free(t);
}
/* ---- biquads ---- */
typedef struct { L m; double c[]; } bq_t;
static bq_t *biquad_Create(const double *coef, L M) { bq_t *b = malloc(sizeof *b + 5 * M * sizeof(double)); b->m = M; memcpy(b->c, coef, 5 * M * sizeof(double)); return b; }
static void biquad_Destroy(void *b) { free(b); }
static void biquad(const bq_t *b, float *delay, const float *X, S IX, float *Y, S IY, L N) {
	for (L n = 0; n < N; n++) { double x = X[n * IX];
		for (L m = 0; m < b->m; m++) { const double *c = b->c + 5 * m; float *di = delay + 2 * m, *dout = delay + 2 * m + 2;
			double y = c[0] * x + c[1] * di[0] + c[2] * di[1] - c[3] * dout[0] - c[4] * dout[1];
			di[1] = di[0]; di[0] = (float)x; x = y;
			if (m == b->m - 1) { dout[1] = dout[0]; dout[0] = (float)y; } }
		Y[n * IY] = (float)x; }
}
typedef struct { L m, n; double *c, *s; } bqm_t;                               /* state: per channel, per section, x1 x2 y1 y2 */
static bqm_t *biquadm_Create(const double *coef, L M, L N) { bqm_t *b = calloc(1, sizeof *b); b->m = M; b->n = N; b->c = malloc(5 * M * N * sizeof(double)); memcpy(b->c, coef, 5 * M * N * sizeof(double)); b->s = calloc(4 * M * N, sizeof(double)); return b; }
static void biquadm_Destroy(bqm_t *b) { if (b) { free(b->c); free(b->s); free(b); } }
static void biquadm_Reset(bqm_t *b) { memset(b->s, 0, 4 * b->m * b->n * sizeof(double)); }
static void biquadm_Copy(bqm_t *d, const bqm_t *s) { L k = d->m * d->n < s->m * s->n ? d->m * d->n : s->m * s->n; memcpy(d->s, s->s, 4 * k * sizeof(double)); }
static void biquadm_SetD(bqm_t *b, const double *coef, L sec0, L ch0, L nsec, L nch) { for (L m = 0; m < nsec; m++) for (L n = 0; n < nch; n++) memcpy(b->c + 5 * ((sec0 + m) * b->n + ch0 + n), coef + 5 * (m * nch + n), 5 * sizeof(double)); }
static void biquadm(bqm_t *b, const float **X, S IX, float **Y, S IY, L N) {
	for (L ch = 0; ch < b->n; ch++) for (L i = 0; i < N; i++) { double x = X[ch][i * IX];
		for (L m = 0; m < b->m; m++) { const double *c = b->c + 5 * (m * b->n + ch); double *s = b->s + 4 * (m * b->n + ch);
			double y = c[0] * x + c[1] * s[0] + c[2] * s[1] - c[3] * s[2] - c[4] * s[3]; s[1] = s[0]; s[0] = x; s[3] = s[2]; s[2] = y; x = y; }
		Y[ch][i * IY] = (float)x; }
}
/* ---- vForce ---- */
#define VV(name, fn) static void name(float *y, const float *x, const int *n) { for (int i = 0; i < *n; i++) y[i] = fn(x[i]); }
VV(vvsqrtf, sqrtf) VV(vvlogf, logf) VV(vvlog2f, log2f) VV(vvacosf, acosf)
static void vvpowsf(float *z, const float *y, const float *x, const int *n) { for (int i = 0; i < *n; i++) z[i] = powf(x[i], *y); }
static void vvpows(double *z, const double *y, const double *x, const int *n) { for (int i = 0; i < *n; i++) z[i] = pow(x[i], *y); }
static void vvsincosf(float *s, float *c, const float *x, const int *n) { for (int i = 0; i < *n; i++) { s[i] = sinf(x[i]); c[i] = cosf(x[i]); } }
static void scopy(int N, const float *X, int incX, float *Y, int incY) { for (int i = 0; i < N; i++) Y[i * incY] = X[i * incX]; }
#define E(n) { "_vDSP_" #n, (void *)n }
const shim_t shims_vdsp[] = {
	E(vadd), E(vsub), E(vmul), E(vdiv), E(vmax), E(vmin), E(vmaxmg), E(vdist), E(vaddD), E(vsmul), E(vsadd), E(vsdiv), E(vthr), E(vthres), E(vsmulD), E(svdiv),
	E(vabs), E(vneg), E(vsq), E(vssq), E(vsma), E(vsmsa), E(vsmsb), E(vsmsma), E(vma), E(vmsa), E(vmsb), E(vmma), E(vasm), E(vsbsm), E(vintb), E(vclr), E(vfill), E(vfillD), E(vfilli),
	E(vsaddi), E(vclip), E(vthrsc), E(maxv), E(minv), E(maxmgv), E(maxvi), E(minvi), E(maxmgvi), E(minmgvi), E(meanv), E(sve), E(svemg), E(svesq), E(rmsqv), E(dotpr), E(dotprD), E(dotpr2),
	E(distancesq), E(vramp), E(vrampmul), E(vrampmuladd), E(vgenD), E(vrvrs), E(vswap), E(vsort), E(vsorti), E(vdbcon), E(vdpsp), E(vspdp), E(vfix32), E(vfixr16), E(vflt16), E(vflt32), E(vswmax),
	E(mmov), E(mmul), E(mtrans), E(hann_window), E(conv), E(desamp), E(deq22), E(ctoz), E(ztoc), E(zvabs), E(zvmags), E(zvphas), E(zvadd), E(zvmul), E(zvcmul), E(zvconj), E(zvmov), E(zvzsml), E(zrvmul), E(zvcma), E(rect),
	{ "_vDSP_DFT_zop_CreateSetup", DFT_zop_Create }, { "_vDSP_DFT_zrop_CreateSetup", DFT_zrop_Create }, { "_vDSP_DFT_DestroySetup", DFT_Destroy }, { "_vDSP_DFT_Execute", DFT_Execute },
	{ "_vDSP_create_fftsetup", create_fftsetup }, { "_vDSP_destroy_fftsetup", DFT_Destroy }, { "_vDSP_fft_zrip", fft_zrip }, { "_vDSP_DCT_CreateSetup", DCT_Create }, { "_vDSP_DCT_Execute", DCT_Execute },
	{ "_vDSP_biquad_CreateSetup", biquad_Create }, { "_vDSP_biquad_DestroySetup", biquad_Destroy }, { "_vDSP_biquad", biquad },
	{ "_vDSP_biquadm_CreateSetup", biquadm_Create }, { "_vDSP_biquadm_DestroySetup", biquadm_Destroy }, { "_vDSP_biquadm_ResetState", biquadm_Reset }, { "_vDSP_biquadm_CopyState", biquadm_Copy },
	{ "_vDSP_biquadm_SetCoefficientsDouble", biquadm_SetD }, { "_vDSP_biquadm", biquadm },
	{ "_vvsqrtf", vvsqrtf }, { "_vvlogf", vvlogf }, { "_vvlog2f", vvlog2f }, { "_vvacosf", vvacosf }, { "_vvpowsf", vvpowsf }, { "_vvpows", vvpows }, { "_vvsincosf", vvsincosf },
	{ "_VVSQRTF", vvsqrtf }, { "_VVLOGF", vvlogf }, { "_VVLOG2F", vvlog2f }, { "_VVACOSF", vvacosf }, { "_VVPOWSF", vvpowsf }, { "_VVPOWS", vvpows }, { "_VVSINCOSF", vvsincosf },
	{ "_cblas_scopy", scopy },
	{ 0, 0 } };
