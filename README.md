# HomePod Hospital

A friendly Mac app for restoring, diagnosing and reviving 1st-gen HomePods (A1639,
`AudioAccessory1,1`) over USB. It was called **HomePod Restore** until November 2026; the Swift
package, its targets and the bundle identifier still carry that name (see "Names" below). Built on the
[homepod-restore guide](https://github.com/UnbendableStraw/homepod-restore) and the tools from
tihmstar, David Ryskalczyk (d235j), 0x7ff, HoolockLinux and libimobiledevice.

## Quick start

```bash
git clone https://github.com/UnbendableStraw/HomePod-Hospital.git && cd HomePod-Hospital
./scripts/build-app.sh          # → dist/HomePod Hospital.app and dist/HomePod-Hospital-1.0.0.zip
```

The build Mac needs macOS 13+, Xcode or the Command Line Tools, `python3`, `brew install
dylibbundler`, and the restore tools installed once (the guide's steps, or the app's Setup →
Install tools). The build downloads gaster and HoolockLinux's `remote_boot` from GitHub and, if
you have no local copy, the audioOS 18.3 IPSW (about 3.4 GB).

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
  standalone AirPlay and Bluetooth speaker — including boards that can no longer run audioOS. Nicotine
  is always tethered: it runs from RAM, and the Mac has to send it over USB again after every power
  cut. The app sends the boot files, waits for the pod's USB network, opens its web UI and saves /
  restores its settings (automatically after a boot, if you like). The Linux image comes from a
  Nicotine payload: built into the app by default, imported from a zip, or your own folder; it is
  checksum-verified before every boot.
- **Boot loaders built from Apple's own files**: before the first Nicotine boot, the **Boot loaders**
  card → **Build release boot loaders** (pod in DFU) downloads iBSS/iBEC from Apple's audioOS 16.4
  update, decrypts them on the HomePod with `gaster`, patches them with `hBootPatcher` and wraps them
  in the app's own code. Once per Mac; the Boot button stays blocked until they exist. See
  [docs/nicotine-boot.md](docs/nicotine-boot.md).
- **Errors explained**: every message in the guide's Troubleshooting section is mapped to a
  title, explanation and "what to try", with hardware failures flagged as such. "Copy support info"
  produces a Discord-ready report (ECID redacted).
- Links to the Discord, PayPal donations, the guide, and credits for tihmstar and David.

## Building

```bash
./scripts/build-app.sh                                   # tools + Nicotine payload inside (the default)
BUNDLE_NICOTINE=0 ./scripts/build-app.sh                 # no Nicotine payload; import one in the app later
BUNDLE_TOOLS=0 BUNDLE_NICOTINE=0 ./scripts/build-app.sh  # app only; users install tools via Setup
NICOTINE_SRC_IPSW=~/Downloads/18.3.ipsw ./scripts/build-app.sh   # build Nicotine from this IPSW
NICOTINE_PAYLOAD_DIR=~/nicotine-payload ./scripts/build-app.sh   # bundle a payload you already built
swift test                                               # core unit tests
HOMEPOD_FAKE_TOOLS=1 swift test                          # + end-to-end job tests with fake gaster/idevicerestore
HOMEPOD_NET_TESTS=1 swift test                           # + live partial-zip read of Apple's Apple TV IPSW
```

**Tools** (`scripts/bundle-tools.sh`, on unless `BUNDLE_TOOLS=0`): builds the patched gaster,
copies the installed `idevicerestore`, `irecovery` and the SysCfg helpers, and compiles
`hBootPatcher` from HoolockLinux's `remote_boot` (pinned) with `clang` directly — its Makefile needs
GNU Make 4 and macOS ships 3.81. If hBootPatcher does not build, the build stops. Bundled tools are
for the build Mac's CPU only (`Resources/bin/ARCHS`); on another CPU the app uses installed tools.

**Nicotine payload** (on unless `BUNDLE_NICOTINE=0`): built from the `nicotine/` kit in this repo
plus Apple-derived parts that are fetched or extracted at build time, so nothing proprietary is in
the repository. The build uses the audioOS 18.3 IPSW named by `NICOTINE_SRC_IPSW`, else the first of
`~/Downloads/18.3.ipsw`, `~/homepod/homepodstuff/18.3.ipsw`, `dist/18.3.ipsw`, else downloads it once
from nicsfix.com into `dist/`. `NICOTINE_PAYLOAD_DIR` skips all that and bundles a ready payload
(it must have a MANIFEST; every file is checked). Details: [nicotine/README.md](nicotine/README.md).

Without bundled tools, Setup opens `scripts/setup-tools.sh` in Terminal. It follows the guide
(d235j tap, HEAD libs, idevicerestore @ d2e1c4f with the irecv_init fix, removes the tap's
idevicerestore) and builds gaster with `scripts/patches/gaster-ecid.patch` into
`~/Library/Application Support/HomePod Hospital/bin`. It does not install hBootPatcher, so an app
built with `BUNDLE_TOOLS=0` cannot build the Nicotine boot loaders.

The app is ad-hoc signed by default; other Macs need right-click → Open the first time.
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
- Nicotine boot loaders and settings backups: `…/HomePod Hospital/Nicotine Release iBoot/` and
  `…/HomePod Hospital/Nicotine Settings/`
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
  NicotineBooter.swift        Nicotine boot sequence, pod check, settings save / restore
  NicotinePayload.swift       where the payload comes from: lookup order, MANIFEST check, import
  ReleaseIBoot.swift          builds the boot loaders in-app from Apple's audioOS 16.4 (IMG4Wrap)
Sources/HomePodRestore/       SwiftUI app, IOKit USB monitor
nicotine/                     Nicotine payload build kit; kernel/ holds the kernel and m1n1 sources
scripts/                      build-app.sh, bundle-tools.sh, setup-tools.sh, prep-release-iboot.sh,
                              gaster patch, ssh-ramdisk-overlay/ (hpdiag-* diagnostic scripts)
Distribution/manifest.json    remote catalog to host on nicsfix.com
```

## Status and limits

- **Tried on hardware, one pod**: the app built, the boot loaders built in the app, and Nicotine
  booted from the Nicotine page with WiFi and Bluetooth working. The color change is confirmed too.
- **Not yet run**: the newest build defaults (tools and payload on by default), the rewritten
  `hpdiag-*` diagnostic scripts, `nicotine/kernel/build.sh`, two pods at once with the patched
  gaster, two simultaneous idevicerestore runs, the admin-password build flow, any second Mac.
- The ready-made restore firmware is audioOS 18.3, and Nicotine is built from 18.3.
- Nicotine's WiFi calibration file and Bluetooth patch are the variants for the USI radio module.
  A pod whose module reports Murata worked with them in the one case tested, but nothing picks
  files by module vendor yet.
- The app is ad-hoc signed (see above).

## Security (Nicotine)

As shipped today, a running Nicotine pod is open to anyone who can reach it: SSH lets in `root`
with no password and listens on WiFi as well as on the USB cable, and the web UI has no login (its
Terminal tab runs commands as root). Only use it on a network you trust. Limiting shell access to
USB and adding a web UI password is planned.
