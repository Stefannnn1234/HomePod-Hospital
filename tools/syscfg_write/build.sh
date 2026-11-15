#!/bin/sh
# Build syscfg_write for the HomePod diags ramdisk (iPhoneOS arm64, iOS 11.2).
# Run on macOS with Xcode. IOKit is resolved at runtime via dlsym, so we only
# link CoreFoundation (the iPhoneOS SDK ships no public IOKit headers).
set -e
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=11.0 \
  -isysroot "$SDK" \
  -framework CoreFoundation \
  -o syscfg_write syscfg_write.c

# Ad-hoc sign with entitlements. On the AMFI-patched diags ramdisk the signature
# is not enforced, but signing keeps the Mach-O well-formed for codesign checks.
codesign -s - --entitlements entitlements.plist -f syscfg_write
echo "built: $(pwd)/syscfg_write"
file syscfg_write
