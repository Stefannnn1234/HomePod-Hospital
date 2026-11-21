#!/usr/bin/env bash
# prep-release-iboot.sh - make Nicotine's two boot loaders from Apple's own public files.
#
# The default boot uses img4/iBSS.dev-hoolock.img4 and iBEC.dev-hoolock.img4, which are Apple
# DEVELOPMENT boot loaders (from a prototype) and should not be handed out. This script builds
# the equivalent pair from the RELEASE iBSS/iBEC inside Apple's audioOS 16.4 update (build
# 20L497), which anyone can download from Apple:
#
#   download (Apple's CDN, about 1 MB)  ->  decrypt on the HomePod itself (gaster, needs DFU)
#   ->  patch (HoolockLinux hBootPatcher: signature check, IORVBAR, AES)  ->  wrap as IMG4
#
# It runs HoolockLinux's own tool, remote_boot, unchanged (pinned to the revision this was
# written against). Nothing in img4/ and nothing in boot-linux.sh is touched.
#
# Needs:
#   - the HomePod connected and in DFU mode (the script waits for it)
#   - internet
#   - Xcode command line tools (git, clang, make, xxd)
#   - Homebrew:  brew install blacktop/tap/ipsw libirecovery make   (ipsw 3.1.719 or newer;
#                "make" because macOS ships GNU Make 3.81, which remote_boot refuses)
#
# Run once per Mac:
#   ./prep-release-iboot.sh
#
# HomePod Hospital runs this same script and sets RELEASE_IBOOT_OUT to a folder it can
# write to; from the terminal the default (release-iboot next to this script) is used.
# Then, only if it ended with "Done", boot with the release boot loaders (the pod is still in DFU):
#   IBOOT_DIR="$PWD/release-iboot" ./boot-linux.sh
# and back to the usual ones with plain  ./boot-linux.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OUT="${RELEASE_IBOOT_OUT:-$HERE/release-iboot}"
RB="$OUT/remote_boot"
REV=e254a58b7d7c68c9e34a407a0beb0aab4861a6b6      # HoolockLinux/remote_boot, 2026-09-14

say()  { printf '[*] %s\n' "$*"; }
fail() { printf '[-] %s\n' "$*" >&2; exit 1; }

missing=""
for t in git clang make xxd irecovery ipsw shasum; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
	echo "[-] missing tools:$missing" >&2
	echo "    git/clang/make/xxd:  xcode-select --install" >&2
	echo "    ipsw, irecovery:     brew install blacktop/tap/ipsw libirecovery" >&2
	exit 1
fi
say "ipsw: $(ipsw version 2>/dev/null | head -n 1 || echo unknown)  (needs 3.1.719 or newer)"
# remote_boot refuses the GNU Make 3.81 (2006) that macOS ships, and does so without a word
# (its message ends up inside a variable). Homebrew's make installs as "gmake".
if ! command -v gmake >/dev/null 2>&1 && make --version 2>/dev/null | grep -q "2006  Free Software Foundation"; then
	echo "[-] the make that comes with macOS (GNU Make 3.81, 2006) is too old for remote_boot" >&2
	echo "    brew install make        (adds 'gmake'; nothing else changes), then run this again" >&2
	exit 1
fi

mkdir -p "$OUT"
if [ ! -d "$RB/.git" ]; then
	say "Fetching HoolockLinux remote_boot into release-iboot/remote_boot"
	# its submodules are listed with SSH addresses; fetch them over https instead
	git -c url."https://github.com/".insteadOf="git@github.com:" \
		clone https://github.com/HoolockLinux/remote_boot "$RB"
fi
git -C "$RB" checkout -q "$REV" 2>/dev/null || {
	git -C "$RB" fetch -q origin && git -C "$RB" checkout -q "$REV"
} || fail "could not check out remote_boot revision $REV"
git -C "$RB" -c url."https://github.com/".insteadOf="git@github.com:" \
	submodule update --init --recursive

say "Running: remoteboot.sh prep   (put the HomePod in DFU now if it is not already)"
# everything it says also goes to release-iboot/prep.log
( cd "$RB" && ./remoteboot.sh prep 2>&1 ) | tee "$OUT/prep.log" ||
	fail "remoteboot.sh prep failed (see the messages above; they are also in release-iboot/prep.log)"

shopt -s nullglob
ibss=("$RB"/cache/iBSS_*_AudioAccessory1,1.img4)
ibec=("$RB"/cache/iBEC_*_AudioAccessory1,1.img4)
dtre=("$RB"/cache/RestoreDeviceTree_*_AudioAccessory1,1.img4)
[ ${#ibss[@]} -eq 1 ] && [ ${#ibec[@]} -eq 1 ] ||
	fail "remote_boot did not leave an iBSS and an iBEC for AudioAccessory1,1 in $RB/cache (is this a 1st-gen HomePod?)"

cp "${ibss[0]}" "$OUT/iBSS.img4"
cp "${ibec[0]}" "$OUT/iBEC.img4"
# Apple's 16.4 device tree, kept for reference; boot-linux.sh keeps using img4/RestoreDeviceTree_b238aap.img4
[ ${#dtre[@]} -eq 1 ] && cp "${dtre[0]}" "$OUT/RestoreDeviceTree_16.4.img4"

say "Done:"
( cd "$OUT" && shasum -a 256 iBSS.img4 iBEC.img4 && ls -l iBSS.img4 iBEC.img4 )
cat <<EOF

Next (the HomePod is still in DFU):

    cd "$HERE"
    IBOOT_DIR="\$PWD/release-iboot" ./boot-linux.sh

What to look for: the same boot as always (console on the serial cable, then
http://172.16.42.1/). If it stops after iBEC or at "bootx", the release boot loader
is refusing something the development one accepts; plain ./boot-linux.sh still
boots the usual way.
EOF
