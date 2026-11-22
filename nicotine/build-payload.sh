#!/usr/bin/env bash
# build-payload.sh — assemble a bootable Nicotine payload from this kit plus the
# two Apple-derived inputs the kit does NOT ship (they are not redistributable):
#
#   --firmware <dir>   Broadcom WiFi/BT firmware, laid out as lib/firmware/brcm/*
#                      (the files in firmware-manifest.txt). Extracted from the
#                      18.3 audioOS root filesystem — the same one HomePod
#                      Hospital already downloads and unpacks for a restore.
#   --adt <file>       Apple's raw device tree for B238a (DeviceTree.b238aap.bin),
#                      extracted from the audioOS OTA (the same OTA the release
#                      boot-loader builder downloads).
#
# Everything else — kernel, m1n1, the HomePod device-tree blob, the trust cache,
# the IMG4 manifest, and the whole Nicotine userspace — is in this kit and is
# redistributable (GPL / MIT / the project's own code). No cross-compiler is
# needed: python3 (standard library only — the packer, tools/pack.py, has no pip deps).
#
#   ./build-payload.sh --firmware <dir> --adt <file> --out <payload-dir>
#
# Output: <payload-dir>/img4/{RestoreKernelCache_m1n1-linux,RestoreDeviceTree_b238aap,
# RestoreTrustCache}.img4 and a MANIFEST — a complete Nicotine payload.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

FW=""; ROOTFS=""; ADT=""; DTIM4P=""; OUT=""
BOOTARGS="${BOOTARGS:-earlycon console=ttySAC0,115200 loglevel=8 pd_ignore_unused clk_ignore_unused rdinit=/init isolcpus=1 irqaffinity=0}"
while [ $# -gt 0 ]; do
	case "$1" in
		--firmware) FW="$2"; shift 2 ;;              # a ready lib/firmware/brcm dir
		--rootfs) ROOTFS="$2"; shift 2 ;;            # an unpacked audioOS rootfs to extract firmware from
		--adt) ADT="$2"; shift 2 ;;                  # Apple's raw B238a device tree
		--devicetree-im4p) DTIM4P="$2"; shift 2 ;;   # the OTA's DeviceTree im4p, to unwrap
		--out) OUT="$2"; shift 2 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
[ -n "$OUT" ] || { echo "--out <payload-dir> is required."; exit 2; }
command -v python3 >/dev/null || { echo "python3 not found."; exit 1; }
WORK0="$(mktemp -d)"; trap 'rm -rf "$WORK0"' EXIT
# firmware: a ready dir, or extracted from a root filesystem by content.
if [ -z "$FW" ]; then
	[ -n "$ROOTFS" ] && [ -d "$ROOTFS" ] || { echo "give --firmware <dir> or --rootfs <audioOS rootfs>."; exit 2; }
	FW="$WORK0/firmware"
	python3 -I "$HERE/tools/extract_wifi.py" "$ROOTFS" "$FW" "$HERE/firmware-manifest.txt" || exit 1
fi
[ -d "$FW" ] || { echo "firmware dir not found: $FW"; exit 2; }
# device tree: a raw ADT, or unwrapped from the OTA's DeviceTree im4p.
if [ -z "$ADT" ]; then
	[ -n "$DTIM4P" ] && [ -f "$DTIM4P" ] || { echo "give --adt <raw> or --devicetree-im4p <file>."; exit 2; }
	ADT="$WORK0/DeviceTree.bin"
	python3 -I "$HERE/tools/pack.py" --unwrap "$DTIM4P" "$ADT" || { echo "could not unwrap the device tree."; exit 1; }
fi
[ -f "$ADT" ] || { echo "device tree not found: $ADT"; exit 2; }

WORK="$(mktemp -d)"
echo "[*] Unpacking the Nicotine root filesystem"
mkdir -p "$WORK/rootfs"
tar xzf "$HERE/rootfs-skeleton.tar.gz" -C "$WORK/rootfs"

echo "[*] Adding the Broadcom firmware from $FW"
rm -rf "$WORK/rootfs/lib/firmware/brcm"
mkdir -p "$WORK/rootfs/lib/firmware"
cp -R "$FW" "$WORK/rootfs/lib/firmware/brcm"

echo "[*] Building the initramfs"
# /dev/null and /dev/console ship as a tiny pre-built, uncompressed cpio so a
# non-root build never needs mknod (macOS tar cannot create device nodes as a
# normal user). The kernel reads this early-cpio segment first, then decompresses
# the rootfs cpio that follows — the standard multi-segment initramfs format.
( cd "$WORK/rootfs" && find . | cpio -o --format=newc -R 0:0 2>/dev/null | gzip -9 ) > "$WORK/rootfs.cpio.gz"
cat "$HERE/prebuilt/devnodes.cpio" "$WORK/rootfs.cpio.gz" > "$WORK/initramfs.gz"

echo "[*] Packing the IMG4 payload"
MK="python3 -I $HERE/tools/pack.py"
IM4M="$HERE/prebuilt/0x7000.im4m"
mkdir -p "$OUT/img4"
# m1n1 + chosen bootargs + DTB + kernel + initramfs, in that order (what iBoot's bootx consumes).
cat "$HERE/prebuilt/m1n1-idevice.macho" <(printf 'chosen.bootargs=%s\n' "$BOOTARGS") \
	"$HERE/prebuilt/t7000-b238a.dtb" "$HERE/prebuilt/Image.gz" "$WORK/initramfs.gz" > "$WORK/m1n1-linux.macho"
$MK "$WORK/m1n1-linux.macho" "$OUT/img4/RestoreKernelCache_m1n1-linux.img4" rkrn "$IM4M" --lzss --extra "$HERE/prebuilt/monitor-stub.macho"
$MK "$ADT" "$OUT/img4/RestoreDeviceTree_b238aap.img4" rdtr "$IM4M"
$MK "$HERE/prebuilt/empty_trustcache.bin" "$OUT/img4/RestoreTrustCache.img4" rtsc "$IM4M"

# The Mac-side settings script (save/restore WiFi, name, pairings, sound).
install -m 0755 "$HERE/homepod-config.sh" "$OUT/homepod-config.sh"

echo "[*] Writing MANIFEST"
{
	echo "nicotine-payload 1"
	echo "variant=public"
	echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	for f in img4/RestoreKernelCache_m1n1-linux.img4 img4/RestoreDeviceTree_b238aap.img4 img4/RestoreTrustCache.img4 homepod-config.sh; do
		( cd "$OUT" && shasum -a 256 "$f" 2>/dev/null || sha256sum "$f" )
	done
} > "$OUT/MANIFEST"
echo "[+] Done. Payload in $OUT"
( cd "$OUT" && ls -la img4 )
