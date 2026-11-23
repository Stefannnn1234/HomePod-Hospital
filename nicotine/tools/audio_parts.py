#!/usr/bin/env python3
"""audio_parts.py ROOTFS OUTDIR MANIFEST -- the two Apple-made audio parts of a Nicotine build.

From a mounted (or unpacked) audioOS 18.3 root filesystem this makes, in OUTDIR:
    apac.img   Apple's AudioCodecs library, for Dolby Atmos decoding (tools/extract_apac.py)
    xtc.bin    the HomePod's virtual-surround filters (tools/extract_xtc.py)
build-payload.sh puts them in /usr/lib/nicotine of the root filesystem. Neither is in the repository.

MANIFEST (audio-manifest.txt) has the checksums of the files Nicotine was tested with. The decoder is used only
if it is exactly that file: apacdec supplies the system functions this one version calls, and a different one
would be advertised to senders and then fail. Without it everything else works and Atmos is not offered. The
filters are used if they have the expected form; a different checksum is only reported.
Always exits 0: a build without these parts is a working build. Python standard library only.
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def main(rootfs, outdir, manifest):
    want = {}
    for line in open(manifest):
        f = line.split()
        if len(f) == 2 and not line.startswith("#"):
            want[f[0]] = f[1].lower()
    os.makedirs(outdir, exist_ok=True)
    # ---- Atmos decoder
    out = os.path.join(outdir, "apac.img")
    cache = os.path.join(rootfs, "System/Library/Caches/com.apple.dyld")
    try:
        import extract_apac
        got = extract_apac.extract(cache, out)
        if got == want.get("apac.img"):
            print("[+] Atmos decoder: identical to the one Nicotine was tested with")
        else:
            os.unlink(out)
            print("[!] Atmos decoder: this audioOS has a different AudioCodecs library than the tested one (18.3).")
            print("    It is left out: this build will not offer Dolby Atmos. Everything else is unaffected.")
    except (SystemExit, Exception) as e:
        if os.path.exists(out):
            os.unlink(out)
        print("[!] Atmos decoder: could not be taken from %s (%s)." % (cache, e))
        print("    This build will not offer Dolby Atmos. Everything else is unaffected.")
    # ---- virtual-surround filters
    out = os.path.join(outdir, "xtc.bin")
    try:
        import extract_xtc
        got = extract_xtc.extract(rootfs, out)
        if got == want.get("xtc.bin"):
            print("[+] Surround filters: identical to the ones Nicotine was tested with")
        else:
            print("[!] Surround filters: not the tested ones (another audioOS version?). They are used all the same.")
    except (SystemExit, Exception) as e:
        if os.path.exists(out):
            os.unlink(out)
        print("[!] Surround filters: could not be read (%s)." % e)
        print("    Surround and height channels will be played without the virtual-surround filters.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__); sys.exit(2)
    sys.exit(main(*sys.argv[1:]))
