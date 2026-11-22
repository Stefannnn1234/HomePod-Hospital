# Nicotine payload build kit

Everything needed to build a bootable **Nicotine** payload for the 1st-gen HomePod from source.
You normally do not run anything here yourself: `./scripts/build-app.sh` builds a payload with
this kit and puts it inside the app. To build one by hand, from the repository root (macOS,
`python3` only, no pip packages):

    bash nicotine/payload-from-ipsw.sh ~/Downloads/18.3.ipsw ~/nicotine-payload

or, from parts you already have:

    # an unpacked audioOS root filesystem + the IPSW's DeviceTree.b238aap.im4p
    nicotine/build-payload.sh --rootfs <audioOS-rootfs> --devicetree-im4p <DeviceTree.b238aap.im4p> --out <payload-dir>
    # a ready lib/firmware/brcm folder + a raw device tree
    nicotine/build-payload.sh --firmware <brcm-dir> --adt <DeviceTree.bin> --out <payload-dir>

The result can be bundled (`NICOTINE_PAYLOAD_DIR=<payload-dir> ./scripts/build-app.sh`) or
imported in the app (**Import Nicotine payload…**, the folder or a zip of it).
`payload-from-ipsw.sh` and the `--rootfs` form fetch the 11.2.5 WiFi firmware described below;
with `--firmware` you supply the folder yourself.

## What a payload is

    MANIFEST                                 "nicotine-payload 1", then a SHA-256 for every file
    homepod-config.sh                        save / restore a pod's settings from the Mac
    img4/RestoreKernelCache_m1n1-linux.img4  m1n1 + boot arguments + HomePod DTB + kernel + initramfs
    img4/RestoreDeviceTree_b238aap.img4      Apple's B238a device tree
    img4/RestoreTrustCache.img4              an empty trust cache

The boot loaders (iBSS/iBEC) are not part of the payload. The app builds them from Apple's release
audioOS 16.4 files on first use (see `docs/nicotine-boot.md`).

## What's in this kit (all redistributable)

- `prebuilt/` — `Image.gz` (Linux kernel, GPL), `m1n1-idevice.macho` + `monitor-stub.macho`
  (m1n1, MIT), `t7000-b238a.dtb` (and a minimal variant), the empty trust cache, `devnodes.cpio` (see below) and
  `0x7000.im4m`, the generic A8 ticket every IMG4 is wrapped with. The app build also copies that
  ticket into the app as `nicotine-0x7000.im4m` for the boot-loader builder.
- `kernel/` — the sources for the prebuilt kernel, device tree and m1n1: patches against
  HoolockLinux's trees, the kernel config and `build.sh` (Linux host). The binaries are committed
  because the app is built on macOS, which cannot build the kernel. See `kernel/README.md`.
- `rootfs-skeleton.tar.gz` — the Nicotine root filesystem, without the Broadcom firmware and with
  no WiFi network in it. The sources of the compiled programs in it (BusyBox, dropbear, BlueZ,
  shairport-sync and others) are not in this repository yet; the scripts and web UI are readable
  inside the tarball.
- `payload-from-ipsw.sh` — the whole build from one 18.3 IPSW (what `build-app.sh` runs).
- `build-payload.sh` — assembles the payload from the kit plus firmware and device tree.
- `tools/pack.py` — IMG4 packer and `--unwrap`, Python standard library only.
- `tools/extract_wifi.py`, `tools/fetch_launch_wifi.py`, `firmware-manifest.txt` — the firmware
  steps below. `firmware-manifest.txt` lists the `lib/firmware/brcm/*` names and the checksums
  of the validated WiFi files.

## Where the Apple parts come from

Nothing Apple-made is stored in this repository. At build time:

- **Device tree**: `DeviceTree.b238aap.im4p` from the 18.3 IPSW. It is LZFSE-compressed;
  `tools/pack.py --unwrap` unwraps and decompresses it (with macOS's own libcompression).
- **Bluetooth patch**: carved out of `/usr/sbin/BlueTool` in the 18.3 root filesystem, which
  embeds it. 18.3 has no separate Bluetooth firmware files. If it is not found, Bluetooth is off
  and everything else still works.
- **WiFi firmware**: version 13.45.26, from Apple's own audioOS 11.2.5 (build 15D59) update.
  `tools/fetch_launch_wifi.py` downloads only the block of that update that holds the WiFi files
  (one HTTP range request, about 7 MB) and checks the files against pinned checksums. The WiFi
  driver was brought up against this version; the newer firmware in 18.3 does not start with it.
  The calibration file gets two lines of our own appended (`msglevel` and a placeholder MAC
  address that is replaced from the pod at run time). If the download fails, the build falls back
  to 18.3's firmware and warns that WiFi will not work.

The build log says which you got: `[+] WiFi firmware and calibration are byte-identical to the
validated Nicotine build` is the good line.

## How the image is put together

1. The root filesystem skeleton is unpacked and the firmware is added under `lib/firmware/brcm`.
2. The initramfs is built. The skeleton has no device nodes, because a normal user on macOS cannot
   create them. `/dev/null` and `/dev/console` come from `prebuilt/devnodes.cpio`, whose entries
   are put in front of the root filesystem's, so the result is one cpio archive in one gzip stream.
   m1n1 accepts nothing else.
3. m1n1, a `chosen.bootargs=` line, the DTB, the kernel and the initramfs are joined in that order
   and wrapped as `rkrn`, with the monitor stub after it. The device tree becomes `rdtr`, the trust
   cache `rtsc`. All three carry `prebuilt/0x7000.im4m`.
4. `homepod-config.sh` is copied and the `MANIFEST` is written.

## Limits and known problems

- The WiFi calibration file and the Bluetooth patch are the variants for the USI radio module.
  A pod whose module reports Murata worked with them in the one case tested; nothing picks files
  by module vendor yet.
- If the 11.2.5 download fails (no network), the build falls back to the WiFi firmware inside the
  18.3 IPSW and says so. That firmware does not start with this driver, so WiFi will not work on
  the pod. A good build prints "WiFi firmware and calibration are byte-identical to the validated
  Nicotine build".

## Note for `.gitignore`

This folder is lowercase `nicotine/`. A rule `Nicotine/` would also match it on macOS's
case-insensitive filesystem and silently stop tracking the whole kit.
