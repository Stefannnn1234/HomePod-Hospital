#!/bin/bash
#
# Builds "HomePod Restore.app" (and a zip for distribution) into ./dist
#
#   ./scripts/build-app.sh                 app only; users install tools via Setup
#   BUNDLE_TOOLS=1 ./scripts/build-app.sh  also bundle gaster/idevicerestore/irecovery
#                                          inside the app (no Homebrew needed to restore)
#   SIGN_ID="Developer ID Application: …"  sign with your certificate (default: ad-hoc)
#   VERSION=1.0.0                          version string
#
# Requires Xcode or the Command Line Tools (swift 5.9+).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGN_ID="${SIGN_ID:--}"
APP="$ROOT/dist/HomePod Restore.app"

echo "==> Building HomePodRestore $VERSION (release)"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  BIN_PATH="$(swift build -c release --show-bin-path)"
fi

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/HomePodRestore" "$APP/Contents/MacOS/HomePodRestore"
cp "$ROOT/scripts/setup-tools.sh" "$APP/Contents/Resources/setup-tools.sh"
cp "$ROOT/scripts/build-ssh-ramdisk.sh" "$APP/Contents/Resources/build-ssh-ramdisk.sh"
# Generic A8 (CPID 0x7000) APTicket for checkm8 boot of the SSH ramdisk.
[ -f "$ROOT/scripts/apticket-0x7000.shsh" ] && cp "$ROOT/scripts/apticket-0x7000.shsh" "$APP/Contents/Resources/apticket-0x7000.shsh"
# Ship the SSH-ramdisk overlay (dropbear + host keys + launch item) if assembled.
if [ -d "$ROOT/scripts/ssh-ramdisk-overlay" ]; then
  cp -R "$ROOT/scripts/ssh-ramdisk-overlay" "$APP/Contents/Resources/ssh-ramdisk-overlay"
fi
cp "$ROOT/scripts/patches/gaster-ecid.patch" "$APP/Contents/Resources/gaster-ecid.patch"

# App icon from Resources/AppIcon.png (1024×1024)
if [ -f "$ROOT/Resources/AppIcon.png" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HomePod Restore</string>
  <key>CFBundleDisplayName</key><string>HomePod Restore</string>
  <key>CFBundleIdentifier</key><string>com.nicsfix.homepodrestore</string>
  <key>CFBundleExecutable</key><string>HomePodRestore</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Nic's Fix — nicsfix.com. Restore tools by tihmstar, David Ryskalczyk, 0x7ff and libimobiledevice.</string>
</dict>
</plist>
PLIST

if [ "${BUNDLE_TOOLS:-0}" = "1" ]; then
  "$ROOT/scripts/bundle-tools.sh" "$APP"
fi

echo "==> Signing ($SIGN_ID)"
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -name "*.dylib" -exec codesign --force --timestamp=none -s "$SIGN_ID" {} \;
fi
if [ -d "$APP/Contents/Resources/bin" ]; then
  find "$APP/Contents/Resources/bin" -type f -perm +111 -exec codesign --force --timestamp=none -s "$SIGN_ID" {} \;
fi
if [ "$SIGN_ID" = "-" ]; then
  codesign --force -s - "$APP"
else
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
fi

echo "==> Packaging"
cd "$ROOT/dist"
rm -f "HomePod-Restore-$VERSION.zip"
ditto -c -k --keepParent "HomePod Restore.app" "HomePod-Restore-$VERSION.zip"
echo
echo "Built: $APP"
echo "Zip:   $ROOT/dist/HomePod-Restore-$VERSION.zip"
[ "$SIGN_ID" = "-" ] && echo "Note: ad-hoc signed. Other Macs will need right-click → Open the first time (or notarize with a Developer ID)."
exit 0
