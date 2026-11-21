#!/bin/bash
#
# Turns a Nicotine payload folder into Nicotine-<build>.zip, the file a user
# imports with "Import Nicotine payload…" on the app's Nicotine page (or that
# you host somewhere for download).
#
#   ./scripts/make-nicotine-payload.sh [PAYLOAD_DIR] [OUTPUT_DIR]
#
#   PAYLOAD_DIR  default ~/Downloads/diagsstuffnic/linux-homepod/public
#   OUTPUT_DIR   default ./dist
#
# A payload folder has a MANIFEST ("nicotine-payload 1", key=value lines, then
# one "<sha256>  <relative path>" line per file). Every listed file is checked
# first; only the listed files and the MANIFEST go into the zip, under one top
# folder Nicotine-<build>/. Nothing else from the folder is included (no
# settings backups, no older images).
#
# Works with the bash 3.2 that ships with macOS. Needs zip and shasum (macOS)
# or sha256sum (Linux).
set -euo pipefail
PAYLOAD="${1:-$HOME/Downloads/diagsstuffnic/linux-homepod/public}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$ROOT/dist}"

die() { echo "make-nicotine-payload: $*" >&2; exit 1; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

[ -d "$PAYLOAD" ] || die "no payload folder at $PAYLOAD"
PAYLOAD="$(cd "$PAYLOAD" && pwd -P)"
M="$PAYLOAD/MANIFEST"
[ -f "$M" ] || die "$PAYLOAD has no MANIFEST"
[ "$(head -n 1 "$M" | tr -d '\r')" = "nicotine-payload 1" ] || die "$M is not a Nicotine payload manifest"
BUILD="$(grep '^build=' "$M" | head -n 1 | cut -d= -f2 | tr -cd 'A-Za-z0-9._-')"
[ -n "$BUILD" ] || die "MANIFEST has no build= line"
command -v zip >/dev/null 2>&1 || die "zip not found"

NAME="Nicotine-$BUILD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$NAME"
COUNT=0
while IFS= read -r line; do
  sum="${line%% *}"; rel="${line#* }"; rel="${rel#"${rel%%[! ]*}"}"; rel="${rel#\*}"; rel="${rel#./}"
  case "$sum" in *[!0-9a-fA-F]*|"") continue ;; esac
  [ ${#sum} -eq 64 ] || continue
  case "$rel" in /*|*..*|"") die "MANIFEST names a file outside the payload: $rel" ;; esac
  [ -f "$PAYLOAD/$rel" ] || die "$rel is listed in MANIFEST but missing"
  [ "$(sha "$PAYLOAD/$rel")" = "$(printf '%s' "$sum" | tr 'A-F' 'a-f')" ] || die "checksum mismatch for $rel"
  mkdir -p "$WORK/$NAME/$(dirname "$rel")"
  cp "$PAYLOAD/$rel" "$WORK/$NAME/$rel"
  COUNT=$((COUNT + 1))
done < "$M"
[ "$COUNT" -gt 0 ] || die "MANIFEST lists no files"
for needed in img4/iBSS.dev-hoolock.img4 img4/iBEC.dev-hoolock.img4 img4/RestoreDeviceTree_b238aap.img4 img4/RestoreTrustCache.img4 img4/RestoreKernelCache_m1n1-linux.img4; do
  [ -f "$WORK/$NAME/$needed" ] || die "MANIFEST does not list $needed; this is not a bootable payload"
done
cp "$M" "$WORK/$NAME/MANIFEST"
find "$WORK/$NAME" -name "*.sh" -exec chmod 755 {} \;

mkdir -p "$OUT"
ZIP="$(cd "$OUT" && pwd -P)/$NAME.zip"
rm -f "$ZIP"
( cd "$WORK" && zip -q -r -X "$ZIP" "$NAME" )
echo "Payload: $ZIP"
echo "  build $BUILD, $COUNT files, $(du -h "$ZIP" | awk '{print $1}')"
echo "  sha256 $(sha "$ZIP")"
echo "Import it in HomePod Hospital: Nicotine page → Import Nicotine payload…"
