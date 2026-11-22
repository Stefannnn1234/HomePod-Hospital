# HomePod Hospital

A friendly Mac app for restoring, diagnosing and reviving 1st-gen HomePods (A1639,
`AudioAccessory1,1`) over USB. It was called **HomePod Restore** until November 2026; the Swift
package, its targets and the bundle identifier still carry that name (see "Names" below). Built on the
[homepod-restore guide](https://github.com/UnbendableStraw/homepod-restore) and the tools from
tihmstar, David Ryskalczyk (d235j), 0x7ff and libimobiledevice.

## What it does

- **Restore**: plug in a HomePod (upside down → adapter → USB → power) and it appears as a card.
  One click runs `gaster pwn` → `gaster reset` → `idevicerestore -d -e -y -i <ECID> -C <cache> <ipsw>`
  and shows plain-English steps with a progress bar instead of a wall of log lines.
- **Several HomePods at once**: each card is one USB port. Jobs target their HomePod by ECID, the
  checkm8 step is serialized, and the root filesystem is unpacked once into a shared cache so
  parallel `idevicerestore` runs never race on extraction. "Restore automatically when plugged in"
  turns it into a batch station (it won't re-restore the same HomePod after it finishes).
- **Firmware**: downloads the prebuilt 18.3 IPSW from nicsfix.com (resumable, SHA-256 checked),
  imports any `.ipsw` you have, and shows Apple's current signing status from ipsw.me.
- **Build your own**: lists full HomePod OTAs from ipsw.me (largest per build, betas hidden), pairs
  each with the matching Apple TV HD (AppleTV5,3) IPSW, downloads the OTA, `makeipsw.sh` and
  `firmware_keys.zip`, and pulls **only** `BuildManifest.plist` + the restore ramdisk out of the
  ~5 GB Apple TV IPSW with HTTP range requests (~80 MB). Then runs makeipsw.sh as admin.
- **Health check**: Quick check (USB link speed, A8 chip, b238 board, checkm8 unlock) and a
  non-destructive Boot test (`idevicerestore -z`: boots the restore ramdisk, erases nothing).
  NAND is judged during a real restore (NAND wait time, "Waiting on NAND", NVRAM timeouts, Disk Failure).
- **Color change (Space Gray ↔ White)**: over the factory DIAGS serial shell, *Reconfigure Model…*
  rewrites the three SysCfg keys that carry a HomePod's color — `Mod#` (model number), `CLCG`
  (Cover Glass Color) and `CLHS` (Housing Color) — and reads all three back. Confirmed on real
  hardware: after restoring firmware, the iOS setup prompt shows the new color. See
  [docs/diags-boot.md](docs/diags-boot.md#color-reconfiguration-space-gray--white).
- **Nicotine (Linux)**: boots a HomePod from DFU into Nicotine, the Linux system that makes it a
  standalone AirPlay and Bluetooth speaker — including boards that can no longer run audioOS. Runs
  the proven `boot-linux.sh` sequence natively, waits for the pod's USB network, opens its web UI
  and saves / restores its settings (automatically after a boot, if you like). The boot files come
  from a Nicotine payload: built into the app (`BUNDLE_NICOTINE=1`), imported from a zip, or your
  own image folder; a payload is checksum-verified before every boot.
- **Boot loaders built from Apple's own files**: Nicotine boots **only** on boot loaders built from
  Apple's release audioOS 16.4 — never Apple's development iBoot. A one-time **Build release boot
  loaders** step (pod in DFU) downloads iBSS/iBEC from Apple, decrypts them on the HomePod with
  `gaster`, patches them with `hBootPatcher` and signs them with `img4` — all with tools inside the
  app, no Homebrew or terminal. The Boot button stays blocked until they exist. See
  [docs/nicotine-boot.md](docs/nicotine-boot.md).
- **Errors explained**: every message in the guide's Troubleshooting section is mapped to a
  title, explanation and "what to try", with hardware failures flagged as such. "Copy support info"
  produces a Discord-ready report (ECID redacted).
- Links to the Discord, PayPal donations, the guide, and credits for tihmstar and David.

## Building

Needs macOS 13+ and Xcode or the Command Line Tools.

```bash
./scripts/build-app.sh                  # → dist/HomePod Hospital.app + zip
BUNDLE_TOOLS=1 ./scripts/build-app.sh   # recommended: ships every tool inside the app (public build)
BUNDLE_TOOLS=1 BUNDLE_NICOTINE=1 ./scripts/build-app.sh   # + build & bundle Nicotine (needs a 18.3 IPSW; auto-downloaded)
./scripts/make-nicotine-payload.sh      # → dist/Nicotine-<build>.zip (for "Import Nicotine payload…")
swift test                              # core unit tests
HOMEPOD_FAKE_TOOLS=1 swift test         # + end-to-end job tests with fake gaster/idevicerestore
HOMEPOD_NET_TESTS=1 swift test          # + live partial-zip read of Apple's Apple TV IPSW
```

`BUNDLE_TOOLS=1` needs the tools installed on the build Mac (guide steps or Setup → Install) and
`brew install dylibbundler`. It also builds `hBootPatcher` (from HoolockLinux's `remote_boot`,
pinned) and bundles `img4`, so the in-app **Build release boot loaders** step works on a fresh Mac
with no Homebrew. Bundled tools are for the build Mac's CPU (`Resources/bin/ARCHS`); on other CPUs
the app falls back to installed tools. With bundled tools, end users don't need Homebrew at all to
restore or to boot Nicotine.

`BUNDLE_NICOTINE=1` **builds** the Nicotine payload from source and bundles it — no prebuilt payload
is shipped or hosted. The `nicotine/` kit in this repo holds the kernel, m1n1, device-tree blob and
the whole Nicotine userspace (all redistributable); the two Apple-derived pieces — the Broadcom
WiFi/BT firmware and the device tree — are extracted at build time from one audioOS **18.3 restore
IPSW** (`nicotine/payload-from-ipsw.sh`, pure `python3` + `hdiutil`, no pip). The build finds a local
18.3 IPSW (`NICOTINE_SRC_IPSW`, `~/Downloads/18.3.ipsw`, `~/homepod/homepodstuff/18.3.ipsw`) or
downloads one. To bundle a payload you already have instead, set `NICOTINE_PAYLOAD_DIR`.

So a fresh checkout needs nothing but the build: `BUNDLE_TOOLS=1 BUNDLE_NICOTINE=1 ./scripts/build-app.sh`
produces an app that can build release boot loaders and boot Nicotine with no further downloads from
the user. See [nicotine/README.md](nicotine/README.md) and [docs/nicotine-boot.md](docs/nicotine-boot.md).

**The app is publicly buildable without any private files.** `BUNDLE_TOOLS=1 ./scripts/build-app.sh`
builds everything — including the Nicotine boot-loader builder's helpers (`hBootPatcher` from
HoolockLinux, `img4` from xerub/img4lib, `gaster` from 0x7ff), all from public sources. Only the
Nicotine *payload* (the Linux image: Apple WiFi/Bluetooth firmware + tuning) is private, so
`BUNDLE_NICOTINE=1` is optional — without it the app still builds and runs, and users add a payload
in-app with **Import Nicotine payload…** (or you host a `Nicotine-<build>.zip`).

Without bundled tools, Setup opens `scripts/setup-tools.sh` in Terminal. It follows the guide
(d235j tap, HEAD libs, idevicerestore @ d2e1c4f with the irecv_init fix, removes the tap's
idevicerestore) and builds gaster with `scripts/patches/gaster-ecid.patch` into
`~/Library/Application Support/HomePod Hospital/bin`.

The app is ad-hoc signed by default; downloaded copies need right-click → Open the first time.
Set `SIGN_ID` to a Developer ID and notarize for a smooth first launch.

## gaster patch

Stock gaster opens the first DFU device it finds. The patch adds `GASTER_ECID=0x…`: only the DFU
device whose serial string has that ECID is used (for `pwn`, `reset`, everything). Without it the
app still works, but only one HomePod may be in DFU mode at a time.

## Remote manifest

Upload `Distribution/manifest.json` to `https://nicsfix.com/ipsw/manifest.json` to change the
recommended firmware, add a warning note, show an announcement banner, or change the Discord /
donate links — no app update needed. If it's missing, the app uses the built-in 18.3 entry.

## Files

- Logs: `~/Library/Logs/HomePod Hospital/`
- Firmware: `~/Library/Application Support/HomePod Hospital/Firmware/`
- Shared restore cache (unpacked rootfs, ~3.3 GB): `…/HomePod Hospital/RestoreCache/`
- A Mac that used the app while it was called HomePod Restore keeps its existing
  `HomePod Restore` folders in both places; nothing is moved or re-downloaded.
- Build work dir (no spaces, makeipsw.sh doesn't quote paths): `~/Library/Caches/HomePodRestore/build/`

## Names

The product is **HomePod Hospital** everywhere a user sees it: the app bundle, window and menu
titles, the installer, the support report, the docs. Left as they were, on purpose:

- SwiftPM package, targets, modules and source folders (`HomePodRestore`, `HomePodRestoreCore`) and
  the executable inside the bundle — renaming them touches every import and the build script for no
  visible gain.
- Bundle identifier `com.nicsfix.homepodrestore` — macOS keys preferences (board-health records,
  chosen firmware, the Nicotine folder) and privacy approvals to it.
- The build work dir `~/Library/Caches/HomePodRestore/build/` (must not contain a space).
- This checkout's folder name and the `homepod-restore` guide repository, which is a different thing.

## Layout

```
Sources/HomePodRestoreCore/   Foundation-only logic (builds & tests on Linux too)
  RestoreJob.swift            gaster + idevicerestore orchestration, unlock serialization
  RestoreProgress.swift       log → phases / progress / hardware info
  ErrorCatalog.swift          known messages → plain-English diagnoses
  FirmwareCatalog.swift       ipsw.me + nicsfix.com manifest
  FirmwareLibrary.swift       local IPSWs, BuildManifest inspection, shared rootfs cache
  IPSWBuilder.swift           makeipsw.sh pipeline, partial donor download
  ZipArchive.swift            ZIP/ZIP64 reader over files or HTTP ranges, verbatim entry copier
  Downloader.swift            resumable downloads
  NicotineBooter.swift        Nicotine (Linux) boot = boot-linux.sh step for step, pod check, settings
  NicotinePayload.swift       where the boot files come from: lookup order, MANIFEST check, import
  ReleaseIBoot.swift          builds Nicotine's boot loaders in-app from Apple's audioOS 16.4
Sources/HomePodRestore/       SwiftUI app, IOKit USB monitor
scripts/                      build-app.sh, bundle-tools.sh (also builds hBootPatcher, bundles img4),
                              setup-tools.sh, make-nicotine-payload.sh, prep-release-iboot.sh, gaster patch
Distribution/manifest.json    remote catalog to host on nicsfix.com
```

## Not yet verified on hardware

Everything was compiled and type-checked against the macOS SDK and the core logic is unit-tested
(including fake-tool end-to-end runs), but nothing has run against a real HomePod yet. Things to
check first: DFU detection/ECID parsing from IOKit, USB speed reporting, the patched gaster with
two pods connected, two simultaneous idevicerestore runs (each briefly probes the other's
restore-mode device while looking for its own), and the admin-password build flow.
