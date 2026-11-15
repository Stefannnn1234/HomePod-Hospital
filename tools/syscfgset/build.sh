#!/bin/sh
set -e
TVOS_SDK=$(xcrun --sdk appletvos --show-sdk-path 2>/dev/null || true)
[ -n "$TVOS_SDK" ] || { echo "[-] tvOS SDK missing — Xcode > Settings > Components > tvOS"; exit 1; }
xcrun clang -target arm64-apple-tvos15.0 -isysroot "$TVOS_SDK" \
    -framework CoreFoundation \
    -o syscfgset syscfgset.c
codesign -s - --entitlements entitlements.plist -f syscfgset
echo "[*] Built ./syscfgset (tvOS/arm64; IOKit resolved at runtime, CF linked)"
