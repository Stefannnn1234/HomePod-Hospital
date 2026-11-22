#!/usr/bin/env bash
# payload-from-ipsw.sh — assemble a complete Nicotine payload from this kit plus
# two Apple inputs, neither of which is shipped in the repo:
#   - an audioOS 18.3 restore IPSW (AudioAccessory1,1): the B238a device tree and
#     the Bluetooth patch (carved from /usr/sbin/BlueTool in its root filesystem);
#   - the WiFi firmware 13.45.26, fetched from Apple's audioOS 11.2.5 update (one
#     7 MB range request, checksums pinned; tools/fetch_launch_wifi.py).
#
#   payload-from-ipsw.sh <audioOS.ipsw> <out-payload-dir>
#
# macOS only (uses hdiutil to mount the OS image). Needs: python3 (stdlib),
# unzip, hdiutil, and network access for the WiFi firmware. The IPSW is the one
# HomePod Hospital already downloads for restores.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
IPSW="${1:?usage: payload-from-ipsw.sh <audioOS.ipsw> <out-payload-dir>}"
OUT="${2:?usage: payload-from-ipsw.sh <audioOS.ipsw> <out-payload-dir>}"
[ -f "$IPSW" ] || { echo "IPSW not found: $IPSW"; exit 2; }
command -v hdiutil >/dev/null || { echo "hdiutil not found — this step needs macOS."; exit 1; }

WORK="$(mktemp -d)"; MNT=""
cleanup() { [ -n "$MNT" ] && hdiutil detach "$MNT" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "[*] Reading the IPSW's BuildManifest"
unzip -o -q "$IPSW" BuildManifest.plist -d "$WORK"
# OS (root filesystem) and DeviceTree paths for this device, from the restore identity.
read -r OS_PATH DT_PATH < <(python3 -I - "$WORK/BuildManifest.plist" <<'PY'
import sys, plistlib
m = plistlib.load(open(sys.argv[1], 'rb'))
osp = dtp = ''
for ident in m.get('BuildIdentities', []):
    info = ident.get('Info', {})
    if 'Erase' not in info.get('RestoreBehavior', '') and 'Erase' not in info.get('Variant', ''):
        continue
    man = ident.get('Manifest', {})
    osp = man.get('OS', {}).get('Info', {}).get('Path', '') or osp
    dtp = man.get('DeviceTree', {}).get('Info', {}).get('Path', '') or dtp
    if osp and dtp:
        break
print(osp, dtp)
PY
)
[ -n "$OS_PATH" ] && [ -n "$DT_PATH" ] || { echo "Could not find the OS / DeviceTree in the BuildManifest."; exit 1; }
echo "    OS=$OS_PATH  DeviceTree=$DT_PATH"

echo "[*] Extracting the OS image and device tree"
unzip -o -q "$IPSW" "$OS_PATH" "$DT_PATH" -d "$WORK"

echo "[*] Mounting the OS root filesystem (read-only)"
MNT="$WORK/mnt"; mkdir -p "$MNT"
hdiutil attach "$WORK/$OS_PATH" -mountpoint "$MNT" -nobrowse -readonly -noverify >/dev/null

# WiFi: the launch firmware (13.45.26) from Apple's audioOS 11.2.5 update — the
# version the driver was brought up against; the firmware inside 18.x does not
# start with it. Bluetooth: carved from this IPSW's root filesystem.
WIFISRC="$WORK/wifi-src"
if ! python3 -I "$HERE/tools/fetch_launch_wifi.py" "$WIFISRC"; then
	echo "[!] Could not fetch the launch WiFi firmware from Apple (no network?)."
	echo "    Falling back to the firmware in this IPSW: WiFi will NOT work on the pod."
	WIFISRC="$MNT/usr/share/firmware/wifi"
fi
echo "[*] Preparing the Broadcom firmware"
python3 -I "$HERE/tools/extract_wifi.py" "$MNT" "$WORK/firmware" "$HERE/firmware-manifest.txt" "$WIFISRC"

echo "[*] Unwrapping the device tree"
python3 -I "$HERE/tools/pack.py" --unwrap "$WORK/$DT_PATH" "$WORK/DeviceTree.bin"

hdiutil detach "$MNT" >/dev/null 2>&1; MNT=""

echo "[*] Assembling the payload"
bash "$HERE/build-payload.sh" --firmware "$WORK/firmware" --adt "$WORK/DeviceTree.bin" --out "$OUT"
echo "[+] Nicotine payload ready in $OUT"
