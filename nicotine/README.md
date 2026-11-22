# Nicotine payload build kit

Everything needed to assemble a bootable **Nicotine** payload for the 1st-gen
HomePod from source, so the payload does not have to be shipped or hosted.

The payload is three IMG4 files — `RestoreKernelCache_m1n1-linux.img4` (m1n1 +
HomePod device-tree blob + Linux kernel + the Nicotine initramfs),
`RestoreDeviceTree_b238aap.img4`, and `RestoreTrustCache.img4`. The boot loaders
(iBSS/iBEC) are built separately from Apple's release firmware by HomePod
Hospital's release boot-loader builder; they are not part of the payload.

## What's in this kit (all redistributable)

- `prebuilt/` — `Image.gz` (Linux kernel, GPL), `m1n1-idevice.macho` +
  `monitor-stub.macho` (m1n1, MIT), `t7000-b238a.dtb` (+ minimal), the empty
  trust cache, and the generic A8 IM4M.
- `rootfs-skeleton.tar.gz` — the complete Nicotine root filesystem (the project's
  own userspace), **minus** the Broadcom firmware and with a credential-free
  `wpa_supplicant.conf`.
- `tools/pack.py` — IMG4 packer (Python standard library only, no pip deps).
- `extract-firmware.sh` — pulls the Broadcom firmware from an unpacked audioOS root filesystem by content (the SHA-256 in `firmware-manifest.txt`), independent of Apple file names.
- `firmware-manifest.txt` — the exact `lib/firmware/brcm/*` files the build adds.
- `build-payload.sh` — assembles the payload.

## What the kit does NOT ship (Apple-derived, obtained at build time)

- **Broadcom WiFi/BT firmware** (`lib/firmware/brcm/*`, ~1.9 MB) — extracted from
  the 18.3 audioOS root filesystem, the same one HomePod Hospital already
  downloads and unpacks for a restore.
- **Apple's B238a device tree** (`DeviceTree.b238aap.bin`) — extracted from the
  audioOS OTA, the same OTA the release boot-loader builder downloads.

## Build

    # from a ready firmware dir + raw device tree:
    ./build-payload.sh --firmware <brcm-dir> --adt <DeviceTree.b238aap.bin> --out <payload-dir>
    # or straight from an unpacked audioOS rootfs + the OTA device-tree im4p:
    ./build-payload.sh --rootfs <audioOS-rootfs> --devicetree-im4p <DeviceTree.im4p> --out <payload-dir>
    # no pip packages needed, only python3

`<payload-dir>` is then a complete payload (with a `MANIFEST`) that HomePod
Hospital can bundle or import.
