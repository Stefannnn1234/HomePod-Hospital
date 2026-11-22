#!/usr/bin/env python3
"""Collect the Broadcom WiFi/BT firmware out of an unpacked audioOS root
filesystem, by CONTENT (so it does not depend on Apple's file names), into a dir
laid out as lib/firmware/brcm/*. Python stdlib only (macOS ships an ancient bash;
this avoids it).

    extract_firmware.py <unpacked-rootfs-dir> <out-dir> <firmware-manifest.txt>

Manifest lines are "<sha256>  <size>  <relpath>" or "LINK <relpath> -> <target>".
A file not found by content and not present in this kit's firmware-fallback/ is
reported and the script exits non-zero.
"""
import hashlib
import os
import shutil
import sys


def norm(rel: str) -> str:
    return rel[2:] if rel.startswith("./") else rel


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: extract_firmware.py <rootfs> <out> <manifest>")
        return 2
    rootfs, out, manifest = sys.argv[1], sys.argv[2], sys.argv[3]
    kit_dir = os.path.dirname(os.path.abspath(manifest))

    wanted, links = [], []
    for line in open(manifest):
        line = line.rstrip("\n")
        if line.startswith("LINK "):
            rel, tgt = line[5:].split(" -> ", 1)
            links.append((norm(rel), tgt))
        elif line.strip():
            sha, size, rel = line.split(None, 2)
            wanted.append((sha.lower(), int(size), norm(rel.strip())))

    sizes = {s for _, s, _ in wanted}
    print("[*] Indexing %s by content (files of %d candidate sizes)…" % (rootfs, len(sizes)))
    byhash = {}
    for dp, _dirs, files in os.walk(rootfs):
        for f in files:
            p = os.path.join(dp, f)
            try:
                if os.path.islink(p):
                    continue
                if os.path.getsize(p) not in sizes:
                    continue
                with open(p, "rb") as fh:
                    h = hashlib.sha256(fh.read()).hexdigest()
            except OSError:
                continue
            byhash.setdefault(h, p)

    os.makedirs(out, exist_ok=True)
    found = missing = 0
    for sha, _size, rel in wanted:
        dst = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
        src = byhash.get(sha)
        fb = os.path.join(kit_dir, "firmware-fallback", rel)
        if src:
            shutil.copyfile(src, dst)
            found += 1
        elif os.path.exists(fb):
            shutil.copyfile(fb, dst)
            found += 1
        else:
            print("    NOT FOUND in the root filesystem: %s (sha256 %s)" % (rel, sha))
            missing += 1
    for rel, tgt in links:
        dst = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
        if os.path.lexists(dst):
            os.remove(dst)
        os.symlink(tgt, dst)

    print("[*] firmware: %d matched, %d symlinks, %d missing" % (found, len(links), missing))
    if missing:
        print("[-] Some firmware files are not in this audioOS build. WiFi/BT would not work.")
        return 1
    print("[+] Firmware ready in %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
