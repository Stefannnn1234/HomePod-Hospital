#!/usr/bin/env bash
# Superseded by tools/extract_firmware.py (macOS ships bash 3.2, no associative
# arrays). Kept as a thin alias.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 -I "$HERE/tools/extract_firmware.py" "$1" "$2" "$HERE/firmware-manifest.txt"
