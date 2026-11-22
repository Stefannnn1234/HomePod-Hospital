#!/usr/bin/env bash
# build.sh — rebuild the four prebuilt boot components in ../prebuilt from source:
#   Image.gz               Linux kernel (HoolockLinux tree + linux-homepod.patch)
#   t7000-b238a.dtb        the HomePod device tree (added by the same patch)
#   m1n1-idevice.macho     m1n1 boot loader (HoolockLinux tree + m1n1-homepod.patch)
#   monitor-stub.macho     built by m1n1's Makefile alongside it
#
# Linux host only (cross-compiling for arm64). Needs: git, make, bc, bison, flex,
# libssl-dev, libelf-dev, gcc-aarch64-linux-gnu (the shipped kernel was built with
# aarch64-linux-gnu-gcc 13.3 / binutils 2.42) and, for m1n1, clang + lld.
# The app build on macOS does NOT run this; it uses the files in ../prebuilt.
#
#   ./build.sh [work-dir]        default work dir: ./work
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WORK="${1:-$HERE/work}"
LINUX_REPO=https://github.com/HoolockLinux/linux
LINUX_REV=ed8528f482a526371e59711645794c91fafb2b42
M1N1_REPO=https://github.com/HoolockLinux/m1n1
M1N1_REV=d5a10ac52a6468484854419a6c5130f1d62073eb
mkdir -p "$WORK"

echo "==> Linux $LINUX_REV"
if [ ! -d "$WORK/linux/.git" ]; then git clone "$LINUX_REPO" "$WORK/linux"; fi
( cd "$WORK/linux"
  git fetch -q origin && git checkout -q -f "$LINUX_REV" && git clean -qfd arch/arm64/boot/dts/apple
  git apply "$HERE/linux-homepod.patch"
  cp "$HERE/config" .config
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
  make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image.gz dtbs )

echo "==> m1n1 $M1N1_REV"
if [ ! -d "$WORK/m1n1/.git" ]; then git clone --recursive "$M1N1_REPO" "$WORK/m1n1"; fi
( cd "$WORK/m1n1"
  git fetch -q origin && git checkout -q -f "$M1N1_REV" && git submodule update --init --recursive
  git apply "$HERE/m1n1-homepod.patch"
  make -j"$(nproc)" ARCH=aarch64-linux-gnu- CHAINLOADING=1 )

OUT="$HERE/../prebuilt"
cp "$WORK/linux/arch/arm64/boot/Image.gz" "$OUT/Image.gz"
cp "$WORK/linux/arch/arm64/boot/dts/apple/t7000-b238a.dtb" "$OUT/t7000-b238a.dtb"
cp "$WORK/m1n1/build/m1n1-idevice.macho" "$OUT/m1n1-idevice.macho"
cp "$WORK/m1n1/build/monitor-stub.macho" "$OUT/monitor-stub.macho"
echo "==> Done. Updated: Image.gz, t7000-b238a.dtb, m1n1-idevice.macho, monitor-stub.macho in $OUT"
