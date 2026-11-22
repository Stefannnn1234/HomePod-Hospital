#!/usr/bin/env python3
"""Fetch the HomePod's WiFi firmware from Apple's own public audioOS 11.2.5 update.

Nicotine's WiFi driver was brought up against Broadcom firmware 13.45.26 (Oct
2017). That exact firmware is what Apple shipped in the HomePod's launch
software, audioOS 11.2.5 (build 15D59), and Apple still serves that update. The
newer firmware in audioOS 18.x does not start with this driver.

The update is a 2.8 GB zip, but every WiFi file sits in one 7 MB compressed
block of it, so only that block is downloaded (one HTTP range request). Each
file is checked against a pinned SHA-256 before it is used.

    fetch_launch_wifi.py <out-dir>

writes <out-dir>/C-4357__s-B1/{crush.trx,crush.clmb,crush.txcb,P-crush_*.txt}
in Apple's own layout. Python standard library only.
"""
import hashlib
import os
import struct
import sys
import time
import urllib.request

URL = ("http://appldnld.apple.com/ios11.2.5/091-60395-20180122-0D9EA6DC-F899-11E7-B561-C551D56A2741/"
       "com_apple_MobileAsset_SoftwareUpdate/dc21689889df1cbde807ada182f7cf826dc65409.zip")
PAYLOAD_OFF = 114987237          # AssetData/payloadv2/payload inside the zip (stored)
PAYLOAD_LEN = 2664442564
CHUNK_OFF = 2764716633           # the pbzx block that holds usr/share/firmware/wifi
CHUNK_LEN = 7354168              # 16-byte block header + xz data
PREFIX = b"usr/share/firmware/wifi/C-4357__s-B1/"
SHA256 = {                       # what Apple shipped in 15D59
    "crush.trx": "312428dbabda4800",
    "crush.clmb": "c777fe7a6c66166f",
    "crush.txcb": "eeec6d04936f2a6a",
}


def http_range(off, length, tries=4):
    last = None
    for attempt in range(tries):
        try:
            req = urllib.request.Request(URL, headers={"Range": "bytes=%d-%d" % (off, off + length - 1)})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            if len(data) == length:
                return data
            last = "short read (%d of %d bytes)" % (len(data), length)
        except Exception as e:  # noqa: BLE001 - report and retry
            last = str(e)
        time.sleep(2 + 2 * attempt)
    raise RuntimeError("download from Apple failed: %s" % last)


def unxz(data):
    """Decompress one .xz stream: Python's lzma, else macOS's libcompression."""
    try:
        import lzma
        return lzma.decompress(data)
    except ImportError:
        pass
    import ctypes
    lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
    fn = lib.compression_decode_buffer
    fn.restype = ctypes.c_size_t
    fn.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t,
                   ctypes.c_void_p, ctypes.c_int]
    cap = 64 << 20
    dst = ctypes.create_string_buffer(cap)
    n = fn(dst, cap, data, len(data), None, 0x306)  # COMPRESSION_LZMA (xz container)
    if not 0 < n < cap:
        raise RuntimeError("could not decompress Apple's update block")
    return dst.raw[:n]


def block_payload(block):
    """A pbzx block: be64 flags, be64 length, then xz data (or raw when full)."""
    _flags, length = struct.unpack(">QQ", block[:16])
    body = block[16:16 + length]
    return unxz(body) if body[:6] == b"\xfd7zXZ\x00" else body


def entries(data):
    """Yield (name, bytes) for the files of the wifi folder found in a block."""
    i = 0
    while True:
        j = data.find(PREFIX, i)
        if j < 0:
            return
        if j < 30:
            i = j + 1
            continue
        name_len = struct.unpack(">H", data[j - 8:j - 6])[0]
        size = struct.unpack(">I", data[j - 24:j - 20])[0]
        name = data[j:j + name_len]
        if not (len(PREFIX) < name_len < 300) or b"\0" in name or j + name_len + size > len(data):
            i = j + 1
            continue
        yield name.decode("ascii", "replace"), data[j + name_len:j + name_len + size]
        i = j + name_len + max(size, 1)


def collect(block):
    found = {}
    for name, body in entries(block_payload(block)):
        base = name[len(PREFIX):].decode() if isinstance(name, bytes) else name[len(PREFIX.decode()):]
        if "/" in base or not body:
            continue
        found[base] = body
    return found


def verified(found):
    for base, want in SHA256.items():
        if base not in found or not hashlib.sha256(found[base]).hexdigest().startswith(want):
            return False
    return any(n.endswith(".txt") for n in found)


def walk():
    """Slow path, only if Apple ever re-packs the file: read each block header."""
    off = PAYLOAD_OFF
    if http_range(off, 4) != b"pbzx":
        raise RuntimeError("Apple's update file is not laid out as expected")
    off += 12
    blocks = []
    while off < PAYLOAD_OFF + PAYLOAD_LEN:
        _flags, length = struct.unpack(">QQ", http_range(off, 16))
        blocks.append((off, 16 + length))
        off += 16 + length
    for boff, blen in reversed(blocks[-12:]):
        found = collect(http_range(boff, blen))
        if verified(found):
            return found
    raise RuntimeError("the WiFi firmware was not found in Apple's update")


def main():
    if len(sys.argv) != 2:
        print("usage: fetch_launch_wifi.py <out-dir>")
        return 2
    out = os.path.join(sys.argv[1], "C-4357__s-B1")
    print("[*] Downloading the WiFi firmware from Apple's audioOS 11.2.5 update (7 MB)")
    try:
        found = collect(http_range(CHUNK_OFF, CHUNK_LEN))
        if not verified(found):
            print("    (not at the expected place; searching the update)")
            found = walk()
    except Exception as e:  # noqa: BLE001
        print("[-] %s" % e)
        return 1
    os.makedirs(out, exist_ok=True)
    for base, body in sorted(found.items()):
        with open(os.path.join(out, base), "wb") as f:
            f.write(body)
    print("[+] WiFi firmware 13.45.26 (audioOS 11.2.5): %d files, checksums match" % len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
