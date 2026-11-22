#!/usr/bin/env python3
"""Produce the HomePod's brcmfmac WiFi firmware from an audioOS root filesystem.

Uses AsahiLinux's proven Apple->brcmfmac conversion (vendored in
asahi_firmware/) on <rootfs>/usr/share/firmware/wifi, then lays the B1 (the
HomePod's BCM4357 rev) firmware out under the exact names the Nicotine kernel
loads, as listed in firmware-manifest.txt. Bluetooth (BCM*.hcd) is NOT produced
here — audioOS has no such blob; it is optional (the pod boots and AirPlays
without it). Python stdlib only.

    extract_wifi.py <rootfs> <out> <firmware-manifest.txt>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asahi_firmware.wifi import WiFiFWCollection  # noqa: E402

REV = "b1"          # the HomePod's BCM4357 stepping
VENDOR_TXT = "crush-TBRG-u"   # board TBRG, vendor USI -> the nvram variant


def ext_of(name):
    for e in ("clm_blob", "txcap_blob", "bin", "txt"):
        if name.endswith("." + e):
            return e
    return None


def is_bt(name):
    n = name.lower()
    return "bcm" in n or n.endswith(".hcd")


def main():
    if len(sys.argv) != 4:
        print("usage: extract_wifi.py <rootfs> <out> <manifest>")
        return 2
    rootfs, out, manifest = sys.argv[1], sys.argv[2], sys.argv[3]
    src = os.path.join(rootfs, "usr", "share", "firmware", "wifi")
    if not os.path.isdir(src):
        print("[-] no Apple WiFi firmware at %s" % src)
        return 1

    col = WiFiFWCollection(src)
    # collect the B1 firmware by ext
    by_ext = {}
    for name, fwfile in col.files():
        base = os.path.basename(name)                    # brcmfmac4357b1-pcie.apple,...
        if not base.startswith("brcmfmac4357%s-pcie." % REV):
            continue
        e = ext_of(base)
        if e in ("bin", "clm_blob", "txcap_blob") and ".apple,crush." in base:
            by_ext[e] = fwfile.data
        elif e == "txt" and VENDOR_TXT in base:
            by_ext["txt"] = fwfile.data
    missing_src = [e for e in ("bin", "clm_blob", "txcap_blob", "txt") if e not in by_ext]
    if missing_src:
        print("[-] 18.3 WiFi firmware is missing %s for %s" % (missing_src, REV))
        return 1

    brcm = out
    os.makedirs(brcm, exist_ok=True)
    wrote = links = skipped_bt = 0
    for line in open(manifest):
        line = line.rstrip("\n")
        if line.startswith("LINK "):
            rel, tgt = line[5:].split(" -> ", 1)
            rel = rel[2:] if rel.startswith("./") else rel
            if is_bt(rel) or is_bt(tgt):
                skipped_bt += 1
                continue
            dst = os.path.join(brcm, rel)
            if os.path.lexists(dst):
                os.remove(dst)
            os.symlink(tgt, dst)
            links += 1
        elif line.strip():
            parts = line.split(None, 2)
            rel = (parts[2] if len(parts) == 3 else parts[-1]).strip()
            rel = rel[2:] if rel.startswith("./") else rel
            if is_bt(rel):
                skipped_bt += 1
                continue
            e = ext_of(rel)
            if e is None or e not in by_ext:
                print("    (skip, no source for %s)" % rel)
                continue
            with open(os.path.join(brcm, rel), "wb") as f:
                f.write(by_ext[e])
            wrote += 1

    print("[*] WiFi firmware: %d files, %d symlinks written (Bluetooth .hcd skipped: %d)" % (wrote, links, skipped_bt))
    for need in ("brcmfmac4357-pcie.bin", "brcmfmac4357-pcie.txt"):
        if not os.path.exists(os.path.join(brcm, need)):
            print("[-] essential firmware missing: %s" % need)
            return 1
    print("[+] WiFi firmware ready in %s" % brcm)
    return 0


if __name__ == "__main__":
    sys.exit(main())
