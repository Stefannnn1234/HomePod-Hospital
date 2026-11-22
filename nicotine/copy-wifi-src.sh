#!/usr/bin/env bash
# copy-wifi-src.sh — copy Apple's WiFi firmware source out of an audioOS IPSW so
# the brcmfmac extraction can be validated. Also searches for Bluetooth firmware.
# Writes to ~/homepod/nicotine-fw-src. macOS only, read-only mount.
#   ./copy-wifi-src.sh ~/homepod/homepodstuff/18.3.ipsw
set -euo pipefail
IPSW="${1:?usage: copy-wifi-src.sh <audioOS.ipsw>}"
DEST="$HOME/homepod/nicotine-fw-src"
WORK="$(mktemp -d)"; MNT=""
cleanup(){ [ -n "$MNT" ] && hdiutil detach "$MNT" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
OS_PATH="$(python3 -I - "$IPSW" <<'PY'
import sys,zipfile,plistlib,io
m=plistlib.load(io.BytesIO(zipfile.ZipFile(sys.argv[1]).read('BuildManifest.plist')))
for i in m.get('BuildIdentities',[]):
    if 'Erase' in i.get('Info',{}).get('RestoreBehavior',''):
        print(i['Manifest']['OS']['Info']['Path']); break
PY
)"
unzip -o -q "$IPSW" "$OS_PATH" -d "$WORK"
MNT="$WORK/mnt"; mkdir -p "$MNT"
hdiutil attach "$WORK/$OS_PATH" -mountpoint "$MNT" -nobrowse -readonly -noverify >/dev/null
rm -rf "$DEST"; mkdir -p "$DEST/wifi" "$DEST/bluetooth"
echo "[*] copying WiFi firmware source"
cp -R "$MNT/usr/share/firmware/wifi/." "$DEST/wifi/" 2>/dev/null || echo "  (no /usr/share/firmware/wifi)"
echo "[*] searching for Bluetooth firmware"
find "$MNT" \( -ipath '*bluetooth*' -o -iname '*.ptb' -o -iname '*BCM4349*' -o -iname '*4349*' \) -type f 2>/dev/null | while read -r f; do
  d="$DEST/bluetooth/$(basename "$f")"; cp "$f" "$d" 2>/dev/null && echo "  + $(basename "$f") ($(stat -f%z "$f") bytes)"
done
find "$MNT/usr/share/firmware" -maxdepth 2 -type d 2>/dev/null | sed "s|$MNT||" > "$DEST/firmware-dirs.txt" || true
echo "[+] Done. Source in $DEST ($(du -sh "$DEST" | cut -f1))"
echo "    Now tell Claude it's ready (it is in the ~/homepod folder)."
