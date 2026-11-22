#!/usr/bin/env python3
"""Wrap a raw payload into an IMG4 (IM4P + IM4M) — the same output as
`ipsw img4 create` / pyimg4, but with NO third-party dependencies (Python
standard library only), so the app can run it on any Mac with python3.

usage: pack.py <in> <out.img4> <fourcc> <im4m> [--lzss] [--extra FILE]

For a kernelcache the payload is LZSS-wrapped (--lzss) with the monitor stub as
the trailing "extra". The LZSS here is a container, not compression (the kernel
and initramfs are already gzip'd), so an all-literals LZSS stream is emitted:
it decompresses, under Apple's own decompressor, to exactly the input — which
is all iBoot needs to locate the stub via the complzss header.
"""
import argparse
import sys
from zlib import adler32


# ---- DER (definite length, minimal encoding — standard DER, matches pyimg4/asn1) ----
def _der_len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def _tlv(tag: int, content: bytes) -> bytes:
    return bytes([tag]) + _der_len(len(content)) + content


def _ia5(s: str) -> bytes:
    return _tlv(0x16, s.encode("ascii"))


def _octet(b: bytes) -> bytes:
    return _tlv(0x04, b)


def _seq(*parts: bytes) -> bytes:
    return _tlv(0x30, b"".join(parts))


def _ctx0(content: bytes) -> bytes:
    # [0] constructed, context class: 0x80 | 0x20 | 0 = 0xA0
    return _tlv(0xA0, content)


# ---- all-literals LZSS (round-trips under Apple's lzss.decompress) ----
def lzss_all_literals(data: bytes) -> bytes:
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        chunk = data[i : i + 8]
        out.append((1 << len(chunk)) - 1)  # low bit per literal; flags read LSB-first
        out += chunk
        i += 8
    return bytes(out)


def complzss_header(uncompressed: bytes, comp_size: int) -> bytes:
    h = bytearray(b"complzss")
    h += adler32(uncompressed).to_bytes(4, "big")
    h += len(uncompressed).to_bytes(4, "big")
    h += comp_size.to_bytes(4, "big")
    h += (1).to_bytes(4, "big")
    h += bytes(0x180 - len(h))
    return bytes(h)


# ---- minimal DER read (to unwrap an im4p/img4 payload) ----
def _rd_len(b, i):
    n = b[i]; i += 1
    if n < 0x80:
        return n, i
    k = n & 0x7F
    return int.from_bytes(b[i:i + k], "big"), i + k


def _children(seq_content):
    out, i = [], 0
    while i < len(seq_content):
        tag = seq_content[i]; i += 1
        ln, i = _rd_len(seq_content, i)
        out.append((tag, seq_content[i:i + ln]))
        i += ln
    return out


def unwrap_payload(data: bytes) -> bytes:
    # top SEQUENCE
    assert data[0] == 0x30
    ln, i = _rd_len(data, 1)
    top = _children(data[i:i + ln])
    first = top[0][1]  # IA5String
    if first == b"IMG4":
        im4p = _children(top[1][1])            # second child is the IM4P sequence
    else:
        im4p = top                             # already an IM4P
    # IM4P = IA5(IM4P), IA5(fourcc), IA5(desc), OCTET STRING(payload)
    for tag, content in im4p:
        if tag == 0x04:
            return content
    raise ValueError("no payload octet-string found")


def lzfse_decode(payload: bytes) -> bytes:
    """Apple ships some IM4P payloads (the device tree, for one) LZFSE-compressed
    ("bvx2"/"bvxn"/"bvx-" magic). Return the raw bytes; anything else passes through.
    Uses what macOS already has (libcompression, then compression_tool); the
    python `lzfse` module is a last resort. Never returns still-compressed data."""
    if payload[:3] != b"bvx":
        return payload
    try:
        import ctypes
        lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
        fn = lib.compression_decode_buffer
        fn.restype = ctypes.c_size_t
        fn.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
                       ctypes.c_void_p, ctypes.c_int]
        cap = max(len(payload) * 64, 8 << 20)
        dst = ctypes.create_string_buffer(cap)
        n = fn(dst, cap, payload, len(payload), None, 0x801)  # COMPRESSION_LZFSE
        if 0 < n < cap:
            return dst.raw[:n]
    except Exception:
        pass
    try:
        import subprocess
        r = subprocess.run(["/usr/bin/compression_tool", "-decode", "-a", "lzfse"],
                           input=payload, capture_output=True)
        if r.returncode == 0 and r.stdout:
            return r.stdout
    except Exception:
        pass
    try:
        import lzfse
        return lzfse.decompress(payload)
    except Exception:
        pass
    raise SystemExit("payload is LZFSE-compressed and no decompressor is available")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("fourcc", nargs="?")
    ap.add_argument("im4m", nargs="?")
    ap.add_argument("--lzss", action="store_true")
    ap.add_argument("--extra")
    ap.add_argument("--unwrap", action="store_true", help="extract the IM4P payload from <in> (im4p/img4) to <out>")
    a = ap.parse_args()

    if a.unwrap:
        open(a.out, "wb").write(lzfse_decode(unwrap_payload(open(a.inp, "rb").read())))
        return 0

    if not a.fourcc or not a.im4m:
        ap.error("fourcc and im4m are required unless --unwrap is given")
    data = open(a.inp, "rb").read()
    if a.lzss:
        comp = lzss_all_literals(data)
        payload = complzss_header(data, len(comp)) + comp
    else:
        payload = data
    if a.extra:
        payload += open(a.extra, "rb").read()

    im4p = _seq(_ia5("IM4P"), _ia5(a.fourcc), _ia5("Unknown"), _octet(payload))
    im4m = open(a.im4m, "rb").read()
    img4 = _seq(_ia5("IMG4"), im4p, _ctx0(im4m))
    open(a.out, "wb").write(img4)
    return 0


if __name__ == "__main__":
    sys.exit(main())
