#!/bin/bash
#
# Copies the restore tools into the app so end users don't need Homebrew:
#   Contents/Resources/bin/{gaster,idevicerestore,irecovery}
#   Contents/Frameworks/*.dylib  (their non-system libraries)
#
# Run on a Mac that already has the tools installed per the guide
# (or via the app's Setup → Install tools). Needs: brew install dylibbundler
set -euo pipefail
APP="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$APP/Contents/Resources/bin"
FW="$APP/Contents/Frameworks"
WORK="$ROOT/.build/tools"
mkdir -p "$BIN" "$FW" "$WORK"

command -v dylibbundler >/dev/null || { echo "Bundling the restore tools needs dylibbundler:  brew install dylibbundler"; echo "(or build without the tools inside:  BUNDLE_TOOLS=0 ./scripts/build-app.sh)"; exit 1; }

echo "==> Building patched gaster (GASTER_ECID)"
if [ ! -d "$WORK/gaster/.git" ]; then git clone https://github.com/0x7ff/gaster.git "$WORK/gaster"; fi
( cd "$WORK/gaster" && git fetch -q origin && git reset -q --hard origin/HEAD && git apply "$ROOT/scripts/patches/gaster-ecid.patch" \
  && make macos > "$WORK/gaster-build.log" 2>&1 ) || { tail -20 "$WORK/gaster-build.log" 2>/dev/null; echo "gaster build failed"; exit 1; }
cp "$WORK/gaster/gaster" "$BIN/gaster"
# gaster exits 1 after printing its usage, so don't let pipefail judge this by its exit code.
GASTER_USAGE="$("$BIN/gaster" 2>&1 || true)"
grep -q GASTER_ECID <<<"$GASTER_USAGE" || { echo "$GASTER_USAGE"; echo "patched gaster didn't build correctly"; exit 1; }

echo "==> Copying idevicerestore + irecovery"
IDR="$(command -v idevicerestore || true)"
[ -n "$IDR" ] || { echo "idevicerestore not found — install it per the guide first (or run the app once and use Setup → Install tools)."; echo "(or build without the tools inside:  BUNDLE_TOOLS=0 ./scripts/build-app.sh)"; exit 1; }
IDR_VERSION="$("$IDR" -v 2>&1 || true)"
grep -q d2e1c4f <<<"$IDR_VERSION" || echo "WARNING: $IDR is not the d2e1c4f build the guide uses ($IDR_VERSION)"
cp "$IDR" "$BIN/idevicerestore"
IREC="$(command -v irecovery || true)"
if [ -n "$IREC" ]; then
  cp "$IREC" "$BIN/irecovery"
else
  # Restores work without it, but the Nicotine, SSH-ramdisk and DIAGS boots do not.
  echo "WARNING: irecovery not found on this Mac (brew install --HEAD libirecovery). It is NOT in the bundle:"
  echo "         Boot Nicotine / SSH ramdisk / Factory DIAGS will ask the user to install tools."
fi

echo "==> Building hBootPatcher (for the in-app release boot-loader builder)"
# hBootPatcher comes from HoolockLinux's remote_boot (MIT); pinned. It is compiled
# with clang directly: its Makefile needs GNU Make 4, and macOS ships 3.81.
HB_REV=e254a58b7d7c68c9e34a407a0beb0aab4861a6b6
if [ ! -d "$WORK/remote_boot/.git" ]; then
  git -c url."https://github.com/".insteadOf="git@github.com:" clone https://github.com/HoolockLinux/remote_boot "$WORK/remote_boot"
fi
HB="$WORK/remote_boot/vendor/hBootPatcher"
if ( cd "$WORK/remote_boot" && git fetch -q origin && git checkout -q "$HB_REV" \
       && git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init --recursive vendor/hBootPatcher ) \
   && ( cd "$HB" && clang -O2 -w -I./include -I./plooshfinder/include \
          src/*.c patches/*.c plooshfinder/src/*.c plooshfinder/src/formats/*.c plooshfinder/src/asm/*.c \
          -o "$WORK/hBootPatcher.bin" ) > "$WORK/hbootpatcher-build.log" 2>&1; then
  cp "$WORK/hBootPatcher.bin" "$BIN/hBootPatcher"; echo "  + hBootPatcher"
else
  tail -20 "$WORK/hbootpatcher-build.log" 2>/dev/null
  echo "hBootPatcher did not build; the Nicotine boot loaders cannot be made without it."; exit 1
fi

echo "==> Copying SysCfg / builder tools (img4tool, ra1nsn0w, tsschecker, iproxy, sshpass)"
for t in img4tool ra1nsn0w tsschecker iproxy sshpass; do
  P="$(command -v "$t" || true)"
  if [ -n "$P" ]; then cp "$P" "$BIN/$t"; echo "  + $t"; else echo "  ! $t not found — install builder tools first (skipping; SysCfg feature needs it)"; fi
done
chmod +x "$BIN"/*

echo "==> Bundling libraries"
ARGS=()
for t in "$BIN"/idevicerestore "$BIN"/irecovery "$BIN"/img4tool "$BIN"/hBootPatcher "$BIN"/ra1nsn0w "$BIN"/tsschecker "$BIN"/iproxy "$BIN"/sshpass; do
  [ -f "$t" ] && ARGS+=(-x "$t")
done
SRCH=(-s "$(brew --prefix)/lib" -s /usr/local/lib)
for f in openssl@3 libplist libusbmuxd libimobiledevice-glue libgeneral; do
  d="$(brew --prefix "$f" 2>/dev/null)/lib"; [ -d "$d" ] && SRCH+=(-s "$d")
done
# stdin is closed on purpose: when dylibbundler cannot find a library it asks for
# its folder and waits, which looked like a hang here because its output was hidden.
if ! dylibbundler -of -b -cd "${ARGS[@]}" -d "$FW" -p @executable_path/../../Frameworks/ "${SRCH[@]}" \
     < /dev/null > "$WORK/dylibbundler.log" 2>&1; then
  echo "Bundling libraries failed. Last lines of $WORK/dylibbundler.log:"
  tail -25 "$WORK/dylibbundler.log"
  exit 1
fi

# Record the CPU architecture(s) so the app ignores these on other CPUs.
lipo -archs "$BIN/idevicerestore" > "$BIN/ARCHS"
echo "Bundled tools for: $(cat "$BIN/ARCHS")"
for t in "$BIN"/gaster "$BIN"/irecovery "$BIN"/idevicerestore "$BIN"/img4tool "$BIN"/hBootPatcher "$BIN"/ra1nsn0w "$BIN"/tsschecker "$BIN"/iproxy "$BIN"/sshpass; do
  [ -f "$t" ] || continue
  LEAKS="$(otool -L "$t" | tail -n +2 | grep -vE "/usr/lib/|/System/|@executable_path" || true)"
  if [ -n "$LEAKS" ]; then echo "WARNING: $(basename "$t") still links outside the bundle:"; echo "$LEAKS"; fi
done
exit 0
