#!/usr/bin/env bash
# find-firmware.sh — locate the WiFi/BT firmware inside an audioOS restore IPSW so
# we can map it to the Linux brcmfmac layout. Mounts the OS filesystem and reports
# every firmware-looking file (path, size, sha256). macOS only. Read-only.
#   ./find-firmware.sh /Users/you/homepod/homepodstuff/18.3.ipsw
set -euo pipefail
IPSW="${1:?usage: find-firmware.sh <audioOS.ipsw>}"
WORK="$(mktemp -d)"; MNT=""
cleanup(){ [ -n "$MNT" ] && hdiutil detach "$MNT" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
OS_PATH="$(python3 -I - "$IPSW" <<'PY'
import sys,zipfile,plistlib,io
z=zipfile.ZipFile(sys.argv[1])
m=plistlib.load(io.BytesIO(z.read('BuildManifest.plist')))
for i in m.get('BuildIdentities',[]):
    if 'Erase' in (i.get('Info',{}).get('RestoreBehavior','')):
        print(i['Manifest']['OS']['Info']['Path']); break
PY
)"
echo "OS image: $OS_PATH"
unzip -o -q "$IPSW" "$OS_PATH" -d "$WORK"
MNT="$WORK/mnt"; mkdir -p "$MNT"
hdiutil attach "$WORK/$OS_PATH" -mountpoint "$MNT" -nobrowse -readonly -noverify >/dev/null
echo "=== firmware-looking files (name/path/size) ==="
find "$MNT" \( -iname '*.hcd' -o -iname '*.trx' -o -iname '*brcm*' -o -iname '*bcm*' -o -iname '*.clm_blob' -o -iname '*.txcap_blob' -o -iname '*nvram*' -o -ipath '*firmware*wifi*' -o -ipath '*firmware*blue*' -o -ipath '*/wifi/*' \) -type f 2>/dev/null \
  | while read -r f; do printf '%10s  %s  %s\n' "$(stat -f%z "$f")" "$(shasum -a 256 "$f" | cut -c1-16)" "${f#$MNT}"; done | sort | head -200
echo "=== files whose size matches a brcm file (106159 875286 10101 233 6225) ==="
for sz in 106159 875286 10101 233 6225; do
  find "$MNT" -type f -size ${sz}c 2>/dev/null | while read -r f; do printf '%10s  %s  %s\n' "$sz" "$(shasum -a 256 "$f" | cut -c1-16)" "${f#$MNT}"; done
done | head -80
echo "=== wifi/bluetooth firmware directories ==="
find "$MNT" -type d \( -ipath '*firmware*' -o -ipath '*/wifi*' -o -ipath '*blueto*' \) 2>/dev/null | sed "s|$MNT||" | head -40
