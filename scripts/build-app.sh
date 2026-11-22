#!/bin/bash
#
# Builds "HomePod Hospital.app" (and a zip for distribution) into ./dist
# (The app was called "HomePod Restore" before; the Swift package, the binary
# inside the bundle and the bundle identifier keep their old names on purpose.)
#
#   ./scripts/build-app.sh                 the full, self-contained app: restore tools
#                                          (gaster, idevicerestore, irecovery, hBootPatcher)
#                                          and a Nicotine payload inside. The payload is
#                                          built from the nicotine/ kit in this repository
#                                          plus Apple's own public downloads; nothing
#                                          proprietary is stored in or shipped with the repo.
#   BUNDLE_TOOLS=0 ./scripts/build-app.sh  leave the tools out (users install them via Setup)
#   BUNDLE_NICOTINE=0 ./scripts/build-app.sh
#                                          leave the Nicotine payload out (it can be imported
#                                          in the app later)
#   NICOTINE_PAYLOAD_DIR=<dir>             bundle that ready-made payload instead of building one
#   NICOTINE_SRC_IPSW=<18.3.ipsw>          the audioOS IPSW to build from (else a local copy is
#                                          looked for, else it is downloaded once, about 3.4 GB)
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
APP="$ROOT/dist/HomePod Hospital.app"

echo "==> Building HomePod Hospital $VERSION (release)"
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
# Generic A8 IM4M from the Nicotine kit: the in-app boot-loader builder signs with it.
cp "$ROOT/nicotine/prebuilt/0x7000.im4m" "$APP/Contents/Resources/nicotine-0x7000.im4m"
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

# CFBundleIdentifier stays com.nicsfix.homepodrestore: macOS keys saved
# preferences (board-health records, chosen firmware, the Nicotine folder) and
# privacy approvals to it, so changing it would silently reset them.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HomePod Hospital</string>
  <key>CFBundleDisplayName</key><string>HomePod Hospital</string>
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

if [ "${BUNDLE_TOOLS:-1}" = "1" ]; then
  "$ROOT/scripts/bundle-tools.sh" "$APP"
fi

# ---- Nicotine payload (optional): the boot files for "Boot Nicotine", inside the app
if [ "${BUNDLE_NICOTINE:-1}" = "1" ]; then
  DEST="$APP/Contents/Resources/Nicotine"
  # Where the payload comes from:
  #  - NICOTINE_PAYLOAD_DIR set        -> use that prebuilt payload.
  #  - otherwise build it from nicotine/ (the kit in this repo) + the two Apple
  #    inputs: NICOTINE_FIRMWARE_DIR (Broadcom WiFi/BT firmware) and NICOTINE_ADT
  #    (Apple's raw B238a device tree). Neither is in the repo; both come from the
  #    builder's own Apple download (see nicotine/README.md).
  if [ -n "${NICOTINE_PAYLOAD_DIR:-}" ]; then
    PAYLOAD="$NICOTINE_PAYLOAD_DIR"
    echo "==> Bundling the Nicotine payload from $PAYLOAD"
    [ -d "$PAYLOAD" ] || { echo "NICOTINE_PAYLOAD_DIR=$PAYLOAD does not exist."; exit 1; }
  else
    echo "==> Building the Nicotine payload from the repo kit (nicotine/)"
    [ -f "$ROOT/nicotine/payload-from-ipsw.sh" ] || { echo "nicotine/ kit is missing from this checkout."; exit 1; }
    command -v python3 >/dev/null || { echo "python3 is needed to build the payload."; exit 1; }
    # One Apple input: the audioOS 18.3 restore IPSW. Both the WiFi firmware and
    # the device tree come from it. Resolve from NICOTINE_SRC_IPSW, a local copy,
    # or a download (Apple's public software, the same the app uses for restores).
    SRC_IPSW="${NICOTINE_SRC_IPSW:-}"
    if [ -z "$SRC_IPSW" ]; then
      for c in "$HOME/Downloads/18.3.ipsw" "$HOME/homepod/homepodstuff/18.3.ipsw" "$ROOT/dist/18.3.ipsw"; do
        if [ -f "$c" ]; then SRC_IPSW="$c"; break; fi
      done
    fi
    if [ -z "$SRC_IPSW" ]; then
      echo "    No 18.3 IPSW found; downloading it (about 3.4 GB, one time)..."
      mkdir -p "$ROOT/dist"
      if curl -fL --retry 3 -o "$ROOT/dist/18.3.ipsw.part" "https://nicsfix.com/ipsw/18.3.ipsw"; then
        mv "$ROOT/dist/18.3.ipsw.part" "$ROOT/dist/18.3.ipsw"
        SRC_IPSW="$ROOT/dist/18.3.ipsw"
      else
        echo "Could not download the IPSW. Set NICOTINE_SRC_IPSW to a local 18.3 IPSW, or NICOTINE_PAYLOAD_DIR to a prebuilt payload."
        exit 1
      fi
    fi
    echo "    Using IPSW: $SRC_IPSW"
    PAYLOAD="$ROOT/dist/nicotine-payload"
    rm -rf "$PAYLOAD"
    if ! bash "$ROOT/nicotine/payload-from-ipsw.sh" "$SRC_IPSW" "$PAYLOAD"; then
      echo "Building the Nicotine payload failed."
      exit 1
    fi
  fi
  [ -f "$PAYLOAD/MANIFEST" ] || { echo "BUNDLE_NICOTINE=1, but $PAYLOAD has no MANIFEST. Only a payload with a MANIFEST can be bundled."; exit 1; }
  [ "$(head -n 1 "$PAYLOAD/MANIFEST" | tr -d '\r')" = "nicotine-payload 1" ] || { echo "$PAYLOAD/MANIFEST is not a Nicotine payload manifest."; exit 1; }
  mkdir -p "$DEST"
  COPIED=0
  # every "<sha256>  <relative path>" line: check the file, then copy it
  while IFS= read -r line; do
    sum="${line%% *}"; rel="${line#* }"; rel="${rel#"${rel%%[! ]*}"}"; rel="${rel#\*}"; rel="${rel#./}"
    case "$sum" in *[!0-9a-fA-F]*|"") continue ;; esac
    [ ${#sum} -eq 64 ] || continue
    case "$rel" in /*|*..*|"") echo "MANIFEST names a file outside the payload: $rel"; exit 1 ;; esac
    [ -f "$PAYLOAD/$rel" ] || { echo "The payload is incomplete: $rel is missing from $PAYLOAD."; exit 1; }
    actual="$(shasum -a 256 "$PAYLOAD/$rel" | awk '{print $1}')"
    [ "$actual" = "$(printf '%s' "$sum" | tr 'A-F' 'a-f')" ] || { echo "Checksum mismatch for $rel: the payload in $PAYLOAD is damaged or half-copied."; exit 1; }
    mkdir -p "$DEST/$(dirname "$rel")"
    cp "$PAYLOAD/$rel" "$DEST/$rel"
    COPIED=$((COPIED + 1))
  done < "$PAYLOAD/MANIFEST"
  for needed in img4/RestoreDeviceTree_b238aap.img4 img4/RestoreTrustCache.img4 img4/RestoreKernelCache_m1n1-linux.img4; do
    [ -f "$DEST/$needed" ] || { echo "The payload's MANIFEST does not list $needed; this is not a bootable payload."; exit 1; }
  done
  cp "$PAYLOAD/MANIFEST" "$DEST/MANIFEST"
  # scripts are run with /bin/bash by the app, but keep them runnable; nothing here is Mach-O
  find "$DEST" -name "*.sh" -exec chmod 755 {} \;
  echo "    $COPIED files, $(grep '^build=' "$PAYLOAD/MANIFEST" | head -n 1 | tr -d '\r') ($(du -sh "$DEST" | awk '{print $1}'))"
  if [ "${BUNDLE_TOOLS:-1}" = "1" ]; then
    for t in gaster irecovery; do
      [ -x "$APP/Contents/Resources/bin/$t" ] || { echo "The Nicotine boot needs $t, and it did not get bundled (is it installed on this Mac?)."; exit 1; }
    done
  else
    echo "    Note: built with BUNDLE_TOOLS=0. A fresh Mac will still have to install gaster and irecovery (Nicotine page → Install tools…)."
  fi
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
rm -f "HomePod-Hospital-$VERSION.zip"
ditto -c -k --keepParent "HomePod Hospital.app" "HomePod-Hospital-$VERSION.zip"
echo
echo "Built: $APP ($(du -sh "$APP" | awk '{print $1}'))"
[ -d "$APP/Contents/Resources/Nicotine" ] && echo "       with a Nicotine payload inside ($(grep '^build=' "$APP/Contents/Resources/Nicotine/MANIFEST" | head -n 1 | tr -d '\r'))"
[ -d "$APP/Contents/Resources/bin" ] && echo "       with tools inside for: $(cat "$APP/Contents/Resources/bin/ARCHS" 2>/dev/null || echo unknown) (other CPUs fall back to the installer)"
echo "Zip:   $ROOT/dist/HomePod-Hospital-$VERSION.zip"
[ -d "$ROOT/dist/HomePod Restore.app" ] && echo "Note: dist/ still holds the old \"HomePod Restore.app\" from before the rename. It is not updated any more; delete it when you like."
[ "$SIGN_ID" = "-" ] && echo "Note: ad-hoc signed. Other Macs will need right-click → Open the first time (or notarize with a Developer ID)."
exit 0
