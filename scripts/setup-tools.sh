#!/bin/bash
#
# HomePod Restore — tool installer
#
# Installs the same tools as the homepod-restore guide
# (https://github.com/UnbendableStraw/homepod-restore), plus a copy of gaster
# that can pick one HomePod out of several (GASTER_ECID), so you can restore
# more than one at a time.
#
#   setup-tools.sh            restore tools only
#   setup-tools.sh --builder  also the tools for building your own .ipsw
#
# The HomePod Restore app opens this in Terminal for you. It's safe to run
# again any time — it repairs/updates what's there.

BUILDER=0
for a in "$@"; do [ "$a" = "--builder" ] && BUILDER=1; done

HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/HomePod Restore"
SRC="$SUPPORT/src"
BIN="$SUPPORT/bin"
PATCH="${GASTER_PATCH:-$HERE/patches/gaster-ecid.patch}"
IDR_COMMIT="d2e1c4f"

bold=$'\033[1m'; green=$'\033[1;32m'; yellow=$'\033[1;33m'; red=$'\033[1;31m'; reset=$'\033[0m'
step() { echo; echo "${bold}==> $*${reset}"; }
ok()   { echo "${green}✓ $*${reset}"; }
warn() { echo "${yellow}! $*${reset}"; }
die()  { echo; echo "${red}✗ $*${reset}"; echo; echo "Need help? Join the Discord: https://discord.gg/nicsfix"; echo; read -r -p "Press Return to close…" _; exit 1; }

clear
cat <<'BANNER'
  _   _                      ____           _
 | | | | ___  _ __ ___   ___|  _ \ ___   __| |
 | |_| |/ _ \| '_ ` _ \ / _ \ |_) / _ \ / _` |
 |  _  | (_) | | | | | |  __/  __/ (_) | (_| |
 |_| |_|\___/|_| |_| |_|\___|_|   \___/ \__,_|  Restore — tool setup

This installs the free command-line tools HomePod Restore uses.
It takes 5–15 minutes. You may be asked for your Mac password
(nothing shows while you type it — that's normal).
BANNER

mkdir -p "$SRC" "$BIN"

# ---------------------------------------------------------------- Homebrew
step "Checking for Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
fi
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew isn't installed. Installing it now (from https://brew.sh)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die "Homebrew install failed."
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
  command -v brew >/dev/null 2>&1 || die "Homebrew installed, but this Terminal can't find it. Close this window and click Install again."
fi
ok "Homebrew: $(brew --version | head -1)"

brew_head() {
  # Install from HEAD, or update an existing HEAD install.
  local f="$1"
  if brew list --versions "$f" >/dev/null 2>&1; then
    echo "Updating $f…"
    brew upgrade --fetch-HEAD "$f" 2>/dev/null || brew reinstall --HEAD "$f" || warn "Couldn't update $f (continuing)"
  else
    echo "Installing $f…"
    brew install --HEAD "$f" || die "Installing $f failed."
  fi
}

# ---------------------------------------------------------------- libraries
step "Installing libraries (d235j/ios-restore-tools)"
brew tap d235j/ios-restore-tools || die "Couldn't add the d235j/ios-restore-tools tap."
brew install autoconf automake libtool pkg-config libzip openssl@3 || die "Installing build tools failed."
brew_head libimobiledevice-glue
brew_head d235j/ios-restore-tools/libimobiledevice
brew_head libirecovery
brew_head ldid-procursus

# iproxy forwards the pod's SSH port to localhost for the experimental SysCfg
# feature. Not needed for a normal restore, so failures here are non-fatal.
step "Installing iproxy (SSH forwarder for the SysCfg feature)"
if command -v iproxy >/dev/null 2>&1; then
  ok "iproxy already installed: $(command -v iproxy)"
else
  brew install libusbmuxd >/tmp/hpr-iproxy.log 2>&1 || warn "Couldn't install libusbmuxd/iproxy (only the experimental SysCfg feature needs it)."
  command -v iproxy >/dev/null 2>&1 && ok "iproxy installed" || warn "iproxy not on PATH (SysCfg feature only)."
fi

# BUGFIX: sshpass was never installed here, although the SSH-ramdisk pipeline
# needs it and docs/ssh-ramdisk-runbook.md says Setup provides it. The ramdisk's
# dropbear only does password auth (root / alpine) and the app runs ssh with no
# terminal, so without sshpass every SysCfg / diagnostics SSH call fails.
#
# sshpass is in homebrew/core these days (formula "sshpass"), so a plain
# `brew install` works. Older Homebrew setups didn't carry it, so fall back to
# the long-standing third-party tap. Like iproxy above, only the experimental
# SysCfg feature needs it, so a failure here is a warning, not fatal.
step "Installing sshpass (SSH password helper for the SysCfg feature)"
if command -v sshpass >/dev/null 2>&1; then
  ok "sshpass already installed: $(command -v sshpass)"
else
  brew install sshpass >/tmp/hpr-sshpass.log 2>&1 \
    || brew install hudochenkov/sshpass/sshpass >>/tmp/hpr-sshpass.log 2>&1 \
    || warn "Couldn't install sshpass (only the experimental SysCfg feature needs it; log: /tmp/hpr-sshpass.log)."
  hash -r
  command -v sshpass >/dev/null 2>&1 && ok "sshpass installed" || warn "sshpass not on PATH (SysCfg feature only)."
fi

# The tap's own idevicerestore is the wrong version for HomePods (guide: Troubleshooting).
if brew list --versions d235j/ios-restore-tools/idevicerestore >/dev/null 2>&1; then
  warn "Removing the Homebrew idevicerestore (wrong version for HomePods)"
  brew uninstall --ignore-dependencies d235j/ios-restore-tools/idevicerestore || true
fi

# ---------------------------------------------------------------- idevicerestore @ d2e1c4f
step "Building idevicerestore ($IDR_COMMIT)"
if [ ! -d "$SRC/idevicerestore/.git" ]; then
  git clone https://github.com/libimobiledevice/idevicerestore.git "$SRC/idevicerestore" || die "Couldn't download idevicerestore."
fi
cd "$SRC/idevicerestore" || die "Missing $SRC/idevicerestore"
git fetch --quiet origin || true
git reset --hard --quiet && git clean -fdq
git checkout --quiet "$IDR_COMMIT" || die "Couldn't check out $IDR_COMMIT."
# Guide fix for "irecv_init undeclared" with newer libirecovery.
sed -i '' '/^[[:space:]]*irecv_init();/d' src/dfu.c
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:$PKG_CONFIG_PATH"
./autogen.sh >/tmp/hpr-idr-autogen.log 2>&1 || { tail -30 /tmp/hpr-idr-autogen.log; die "idevicerestore configure failed (log: /tmp/hpr-idr-autogen.log)."; }
make -j"$(sysctl -n hw.ncpu)" >/tmp/hpr-idr-make.log 2>&1 || { tail -30 /tmp/hpr-idr-make.log; die "idevicerestore build failed (log: /tmp/hpr-idr-make.log)."; }
echo "Installing to /usr/local/bin (needs your Mac password)…"
sudo make install >/tmp/hpr-idr-install.log 2>&1 || { tail -20 /tmp/hpr-idr-install.log; die "idevicerestore install failed."; }
hash -r
ok "$(/usr/local/bin/idevicerestore -v 2>/dev/null | head -1)"

# ---------------------------------------------------------------- gaster (multi-HomePod)
step "Building gaster with multi-HomePod support"
if [ ! -d "$SRC/gaster/.git" ]; then
  git clone https://github.com/0x7ff/gaster.git "$SRC/gaster" || die "Couldn't download gaster."
fi
cd "$SRC/gaster" || die "Missing $SRC/gaster"
git fetch --quiet origin || true
git reset --hard --quiet origin/HEAD 2>/dev/null || git reset --hard --quiet
if [ -f "$PATCH" ] && git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH" && ok "Applied GASTER_ECID patch"
else
  warn "Couldn't apply the multi-HomePod patch — building stock gaster (restore one HomePod at a time)."
fi
make macos >/tmp/hpr-gaster.log 2>&1 || { tail -20 /tmp/hpr-gaster.log; die "gaster build failed (log: /tmp/hpr-gaster.log)."; }
cp gaster "$BIN/gaster" && chmod +x "$BIN/gaster"
ok "gaster installed to $BIN"

# ---------------------------------------------------------------- builder tools (optional)
if [ "$BUILDER" = "1" ]; then
  step "Installing firmware builder tools (ra1nsn0w, img4tool, tsschecker, binrider)"
  brew_head d235j/ios-restore-tools/libgeneral
  brew_head d235j/ios-restore-tools/img4tool
  brew_head d235j/ios-restore-tools/tsschecker
  brew_head d235j/ios-restore-tools/libpatchfinder
  brew_head d235j/ios-restore-tools/ra1nsn0w
  for t in ra1nsn0w img4tool tsschecker binrider ldid; do
    command -v "$t" >/dev/null 2>&1 && ok "$t" || warn "$t not found on PATH"
  done
fi

# ---------------------------------------------------------------- check
step "Checking everything"
FAIL=0
/usr/local/bin/idevicerestore -v 2>/dev/null | grep -q "$IDR_COMMIT" && ok "idevicerestore $IDR_COMMIT" || { warn "idevicerestore version doesn't match $IDR_COMMIT"; FAIL=1; }
"$BIN/gaster" 2>/dev/null | grep -q GASTER_ECID && ok "gaster (multi-HomePod)" || warn "gaster (single HomePod only)"
# sshpass/iproxy are only needed by the experimental SysCfg feature: report, don't fail.
command -v sshpass >/dev/null 2>&1 && ok "sshpass (SysCfg feature)" || warn "sshpass missing — SysCfg/diagnostics over SSH won't be able to log in to the pod."
brew doctor >/dev/null 2>&1 && ok "brew doctor: Your system is ready to brew!" || warn "brew doctor reported warnings (usually harmless)."

echo
if [ "$FAIL" = "0" ]; then
  echo "${green}${bold}All set! Go back to HomePod Restore and click “Check again”.${reset}"
else
  echo "${yellow}${bold}Finished with warnings. Go back to HomePod Restore and click “Check again”.${reset}"
  echo "If something still shows a warning, ask in the Discord: https://discord.gg/nicsfix"
fi
echo
read -r -p "Press Return to close this window…" _
