#!/bin/bash
# build-ssh-ramdisk.sh — turn the donor Apple TV restore ramdisk into a
# shell-capable (SSH) ramdisk that boots on a checkm8'd 1st-gen HomePod, so
# SysCfg can be read/restored over a shell instead of desoldering the NAND.
#
# This is the AudioAccessory1,1 analogue of the community ssh-ramdisk scripts
# (verygenericname/SSHRD_Script, tihmstar/ra1nsn0w). It is driven by
# SSHRamdiskBuilder.swift, which fetches the donor ramdisk first.
#
# Usage:
#   build-ssh-ramdisk.sh <donor_ramdisk.im4p> <firmware_keys.zip> <overlay_dir> <out.img4> <logfile>
#
# Tools (same set the builder already installs): img4tool, img4, hdiutil, ldid.
# Runs under administrator privileges because it mounts/creates disk images.
#
# TO CONFIRM on first hardware run (these are the only unknowns — the de-risk
# read on a known-good pod resolves them):
#   (A) KEY: the restore ramdisk may be encrypted; its decryption key comes from
#       firmware_keys.zip for this build. If the donor ramdisk is already
#       plaintext for this AppleTV build, the img4 -D step needs no key.
#   (B) OVERLAY: <overlay_dir> must contain a HomePod/arm64 dropbear, host keys,
#       and a launchd plist that starts dropbear on boot. Sourced once from
#       SSHRD_Script's ramdisk_tools (or built for arm64) — not fabricated here.
#   (C) BOOT: ra1nsn0w/irecovery boot args for AudioAccessory1,1 (handled on the
#       Swift side in RamdiskBoot, not here).

set -o pipefail
IMG4TOOL="${IMG4TOOL:-img4tool}"
RAMDISK="$1"; KEYS="$2"; OVERLAY="$3"; OUT="$4"; LOG="$5"
exec > >(tee -a "$LOG") 2>&1

die() { echo "ERROR: $*"; echo "SSHRD_FAILED"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
command -v "$IMG4TOOL" >/dev/null 2>&1 || die "img4tool not found (set IMG4TOOL to a working one — Homebrew's often breaks on libplist upgrades; SSHRD_Script/Darwin/img4tool is self-contained)"
need hdiutil

WORK="$(mktemp -d /tmp/sshrd.XXXXXX)" || die "mktemp"
trap 'hdiutil detach "$MNT" >/dev/null 2>&1; hdiutil detach "$MNT0" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
MNT="$WORK/mnt"; mkdir -p "$MNT"

echo "== 1/6 Unwrapping donor ramdisk img4 -> raw dmg =="
# (A) If encrypted, pass the per-build key: img4tool -e -k <iv+key> ...
# Plaintext path shown; the Swift side supplies -k when firmware_keys has a key.
"$IMG4TOOL" -e -o "$WORK/ramdisk.dmg" "$RAMDISK" || die "img4tool extract failed (ramdisk may need a decryption key — see note A)"

echo "== 2/6 Building a larger writable ramdisk (seeded from the donor) =="
# The extracted ramdisk is a bare HFS volume with no partition map, so
# `hdiutil resize` rejects it. Instead — exactly like SSHRD_Script — mount it and
# create a NEW, larger HFS image seeded from its contents (hdiutil create
# -srcfolder), which we can then write the overlay into.
MNT0="$WORK/mnt0"; mkdir -p "$MNT0"
hdiutil attach -mountpoint "$MNT0" -nobrowse -readonly -owners on "$WORK/ramdisk.dmg" || die "could not mount donor ramdisk"
rm -f "$WORK/ramdisk_rw.dmg"
hdiutil create -size 300m -fs HFS+ -layout NONE -format UDRW -volname SSHRD \
  -copyuid root -srcfolder "$MNT0" "$WORK/ramdisk_rw.dmg" || { hdiutil detach -force "$MNT0" >/dev/null 2>&1; die "could not create resized ramdisk image"; }
hdiutil detach -force "$MNT0" >/dev/null 2>&1
hdiutil attach -mountpoint "$MNT" -nobrowse -owners on "$WORK/ramdisk_rw.dmg" || die "could not mount new ramdisk image"

echo "== 3/6 Injecting SSH overlay =="
[ -d "$OVERLAY" ] || die "overlay dir not found: $OVERLAY (see note B)"
# ditto preserves exec bits and tolerates the ramdisk filesystem better than
# cp -a (which errors trying to copy extended attributes). Merge overlay -> ramdisk.
ditto "$OVERLAY" "$MNT" || die "overlay copy (ditto) failed"
rm -f "$MNT/README.md" 2>/dev/null
ls "$MNT"/usr/local/bin/dropbear >/dev/null 2>&1 || die "overlay missing dropbear (note B)"

echo "== 4/6 Unmounting =="
sync
hdiutil detach "$MNT" || die "detach failed"; MNT=""

echo "== 5/6 Compressing + repacking dmg -> img4 payload =="
# Shrink to fit, compress (ULFO/LZFSE) so the in-RAM ramdisk stays small, then
# rewrap as an img4 payload (fourcc 'rdsk'). Swift boots it via ra1nsn0w + APTicket.
hdiutil resize -sectors min "$WORK/ramdisk_rw.dmg" >/dev/null 2>&1 || true
hdiutil convert "$WORK/ramdisk_rw.dmg" -format ULFO -o "$WORK/ramdisk.ulfo.dmg" >/dev/null 2>&1 || die "hdiutil compress (ULFO) failed"
"$IMG4TOOL" -c "$OUT" -t rdsk "$WORK/ramdisk.ulfo.dmg" || die "img4tool repack failed"

echo "== 6/6 Done =="
[ -s "$OUT" ] || die "output img4 not produced"
echo "SSHRD_OK $OUT"
exit 0
