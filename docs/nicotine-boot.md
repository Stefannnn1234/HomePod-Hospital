# Booting Nicotine (Linux) from HomePod Hospital

Added November 2026. Written for a new session (AI or human) with no context.

**Nicotine** is the Linux system for the 1st-gen HomePod (A1639, `AudioAccessory1,1`, board B238a).
It turns the pod into a standalone AirPlay and Bluetooth speaker with its own web UI, and it also
runs on boards that can no longer run audioOS (dead SEP, dead NAND). It is developed outside this
repository. HomePod Hospital only boots it and looks after the running pod; the boot files reach
the app as a *payload* (built into the app, imported, or a folder on the bench Mac; see
"Where the boot files come from").

Nicotine is always **tethered**: it is loaded into RAM from DFU through checkm8 and is gone when the
pod loses power. Nothing on the pod's NAND is written by the boot.

## What the app does

Sidebar → **Nicotine (Linux)** (`Views/NicotineView.swift`):

0. **First time? How this works** — a fold-out with the DFU steps, what to expect, and "join WiFi
   in the web UI first".
1. **Nicotine payload** — which payload is in use (your own folder / built into this app / imported),
   its build number from `MANIFEST`, any of the five boot files that are missing, and the buttons
   "Import Nicotine payload…", "Choose a folder…", "Use the built-in payload".
2. **Boot Nicotine** — runs the boot (below) on the one HomePod in DFU and shows the log. If gaster or
   irecovery is not on this Mac the card says so *before* the boot and offers "Install tools…"
   (the same Terminal installer as on the Setup page).
3. **Running HomePod** — once the pod's USB network answers at `172.16.42.1`: its version line
   (`PRETTY_NAME` and `VERSION` from `/etc/os-release`, read over SSH), **Open web UI**
   (`http://172.16.42.1/`), **Restore saved settings** and **Save settings**, and the switch
   **Restore saved settings automatically after boot** (on by default). "Check again" finds a
   pod that was booted earlier or from Terminal.

The device card also offers it: "Boot Nicotine (Linux)" in the *Check health* menu (advanced options
on), and the "Boot Nicotine (Linux)" row among the options for a board with a hardware diagnosis.
Both start the boot and switch to the Nicotine page.

## The boot sequence = `boot-linux.sh`

`NicotineBooter` (`Sources/HomePodRestoreCore/NicotineBooter.swift`) reproduces the script's default
mode (`PAYLOAD=linux`, `TAGS=restore`, no `IBOOT_DIR`) **command for command**:

| # | Command | If it fails | Pause after |
|---|---------|-------------|-------------|
| 1 | `gaster pwn` | stop | |
| 2 | `gaster reset` | stop | 1 s |
| 3 | `irecovery -f img4/iBSS.dev-hoolock.img4` | stop | 3 s |
| 4 | `irecovery -f img4/iBEC.dev-hoolock.img4` | stop | 4 s |
| 5 | `irecovery -f img4/RestoreDeviceTree_b238aap.img4` | stop | |
| 6 | `irecovery -c devicetree` | carry on | |
| 7 | `irecovery -f img4/RestoreTrustCache.img4` | carry on (older iBoots have no trust cache) | |
| 8 | `irecovery -c firmware` | carry on | |
| 9 | `irecovery -f img4/RestoreKernelCache_m1n1-linux.img4` | stop | |
| 10 | `irecovery -c bootx` | carry on | |

`RestoreKernelCache_m1n1-linux.img4` is not a kernelcache: it is m1n1 with the Linux kernel, device
tree and initramfs appended, wrapped with the `rkrn` tag so iBEC accepts it.

**Do not change this sequence in the app first.** It is the one that works. Change `boot-linux.sh`,
prove it on a pod, then mirror it in `NicotineBooter.steps(for:)`; `NicotineTests` pins the list,
which failures stop the boot, and the pauses.

Differences from running the script by hand, all outside the sequence itself:

- The tools come from the app's tool locator (bundled → the app's own tools folder → Homebrew
  paths), not from the shell's `PATH`. Same binaries on a normal install.
- The boot takes the app-wide unlock lock (`UnlockCoordinator`), like every other checkm8 boot.
- The app refuses to start unless exactly one HomePod is on USB and no restore or other boot is
  running, because the script's commands do not name a device.
- The script's other modes (`PAYLOAD=only`, `linux-minimal`, `TAGS=normal`, `IBOOT_DIR`) are not
  offered. Use the script for those.
- The UART console is not touched. If you log it (`screen` on the USB-serial adapter, 115200 8N1),
  keep doing that separately; it is the only place early-boot failures show.

## After the boot

- Reachability is `curl -s -o /dev/null -m 3 http://172.16.42.1/`, polled every 2 s for up to two
  minutes: the same test `homepod-config.sh` uses. curl, not URLSession, because App Transport
  Security refuses plain HTTP. The pod normally answers 25 to 40 seconds after `bootx`.
- The version is read with `/usr/bin/ssh … root@172.16.42.1 cat /etc/os-release`. The pod's dropbear
  lets root in without a password; `BatchMode=yes` keeps ssh from ever prompting, and the host key
  is neither checked nor stored (it changes with every boot: the pod has no storage).
- **Settings.** Under Linux the pod remembers nothing across a power cut. `homepod-config.sh` in the
  payload keeps one backup per pod (WiFi networks and key, AirPlay name, Bluetooth pairings, sound
  and light settings). The app runs that script (`/bin/bash homepod-config.sh restore --wait 30` and
  `… save`) and reads its outcome (`NicotineSettings.outcome`); it does not re-implement it. The
  backups contain the WiFi key.
- **Where the backups are.** With your own folder: `<folder>/config/`, the script's default, as
  before. With the built-in or an imported payload: `~/Library/Application Support/HomePod Hospital/
  Nicotine Settings/`, passed to the script as `HOMEPOD_CONFIG_DIR` (the app bundle is signed and
  must not be written into; an imported payload is replaced wholesale by the next import).
- **Automatic restore.** When the pod answers after a boot and the option is on, the app runs the
  restore once, but only if at least one backup exists in that folder. On a Mac with no backup yet
  nothing is attempted (the log says to join WiFi and click "Save settings"). The script picks the
  backup for this pod by its unit ID; "no backup for this pod" is shown as information, not as an error.

## Where the boot files come from (payloads)

A *payload* is a folder in the image-folder layout below plus a `MANIFEST`:

```
nicotine-payload 1
build=107
variant=public
created=2026-11-21T07:59:13Z
<sha256>  img4/iBSS.dev-hoolock.img4
…one line per file (five boot files, boot-linux.sh, homepod-config.sh, README-FIRST.txt)
```

Unknown `key=value` header lines are ignored. The app looks for a payload in this order
(`NicotinePayloadLocator.resolve`):

1. **Your own folder** (`nicotineFolder` in UserDefaults; on the bench Mac it defaults to
   `~/Downloads/diagsstuffnic/linux-homepod` when that exists). It may have no MANIFEST; then
   nothing is verified and it works exactly as before. A picked folder that exists is used even if
   it is incomplete (the page says what is missing) until "Use the built-in payload" clears it.
2. **Built into the app**: `HomePod Hospital.app/Contents/Resources/Nicotine/`, put there by
   `BUNDLE_NICOTINE=1 ./scripts/build-app.sh`.
3. **Imported**: `~/Library/Application Support/HomePod Hospital/Nicotine/`, put there by
   "Import Nicotine payload…" (a payload folder or a `.zip` of one; the zip may have the files at
   its top or inside one folder).

When the payload has a MANIFEST, every listed file is hashed and compared before each boot
(`NicotineBooter.preflight`), and an import verifies before and after copying. A mismatch stops
with "… is damaged or incomplete": a cut-off 43 MB download otherwise fails on the pod, where only
the UART shows why. Imports copy exactly the files the MANIFEST lists, nothing else.

**Making and shipping a payload.** The payload folder is produced outside this repository (the
Nicotine build; the public variant has no WiFi network baked in). From it:

```bash
BUNDLE_TOOLS=1 BUNDLE_NICOTINE=1 ./scripts/build-app.sh   # the fully self-contained app
./scripts/make-nicotine-payload.sh                         # → dist/Nicotine-<build>.zip for hosting / import
NICOTINE_PAYLOAD_DIR=<folder or zip> swift test --filter RealPayload   # check a real payload with the app's own code
```

`NICOTINE_PAYLOAD_DIR` (default `~/Downloads/diagsstuffnic/linux-homepod/public`) names the payload
for the build. The build fails if the folder or its MANIFEST is missing or a checksum is wrong, and
with both flags also if gaster or irecovery did not make it into the bundle. Nothing of the payload
is ever committed (`.gitignore` covers `Nicotine*/`, `Nicotine-*.zip`, `*.img4`). There is no
download-by-URL: `NicotinePayloadImporter.payloadDownloadURL` is an empty constant for the publisher
to fill in if a payload is ever hosted.

## Fresh Mac checklist

What a Mac that has never seen this project needs, and where it comes from when the app was built
with `BUNDLE_TOOLS=1 BUNDLE_NICOTINE=1`:

| Needed for | What | In the app? |
|---|---|---|
| unlock (checkm8) | `gaster` (built from source with the ECID patch) | yes, `Resources/bin/gaster`; links only system frameworks |
| sending boot files | `irecovery` | yes, `Resources/bin/irecovery` |
| irecovery's libraries | libirecovery, libimobiledevice-glue, libplist | yes, `Contents/Frameworks/`, re-pathed to `@executable_path/../../Frameworks` by dylibbundler |
| boot files | five `.img4`, MANIFEST | yes, `Resources/Nicotine/` |
| settings save / restore | `homepod-config.sh` | yes, `Resources/Nicotine/`; needs only bash, curl, tar, gzip, sed (all macOS) |
| reaching the pod | `/usr/bin/curl`, `/usr/bin/ssh`, `/bin/bash`, `/usr/bin/unzip` (import) | part of macOS |
| the USB network | macOS's own USB-Ethernet driver | part of macOS; nothing to install |

Checked on the app Nic built with `BUNDLE_TOOLS=1` on 21 Nov 2026 (by reading the Mach-O load
commands): gaster, irecovery, idevicerestore and every dylib in `Contents/Frameworks` link only to
`/usr/lib`, `/System` and `@executable_path/../../Frameworks`. No Homebrew path is left in them.

Still **not** in the app, or not verified:

- **CPU.** The bundled tools are for the build Mac's CPU only (`Resources/bin/ARCHS`, currently
  `arm64`). On an Intel Mac the app ignores them and the Nicotine page offers "Install tools…",
  which installs Homebrew and builds the tools (needs the Command Line Tools and several minutes).
  A universal tool bundle is not built.
- **Without `BUNDLE_TOOLS=1`** every Mac needs that installer once.
- **Gatekeeper.** The app is ad-hoc signed unless `SIGN_ID` is set: a downloaded copy needs
  right-click → Open the first time, and macOS may run it translocated (read-only, random path).
  The payload is only read, and backups go to Application Support, so this should not matter, but
  it has not been tried.
- **The hardware side is outside any app**: the USB adapter for the debug port, and DFU.
- **Unverified as of this writing**: the SwiftUI side of these changes was written without a Mac
  toolchain (syntax-checked; `AppModelNicotine.swift` type-checked against stand-ins). Not yet
  tried: a build with `BUNDLE_NICOTINE=1`, a boot from the built-in payload, import of a zip in the
  real app, automatic restore, the tool-install prompt on a Mac without tools, any second Mac.

Checks to run on a second Mac or a clean macOS user account (no Homebrew in PATH, no
`~/Downloads/diagsstuffnic`): the Nicotine page shows "Built into this app: Nicotine build N";
`Boot Nicotine` is offered once a HomePod is in DFU; the boot log starts with the MANIFEST check;
the pod answers; "Save settings" writes into `…/Application Support/HomePod Hospital/Nicotine
Settings/` and nothing appears inside the app bundle (`codesign --verify --deep` on the app still
passes afterwards); reboot the pod and the settings come back by themselves.

**Before publishing an app or zip with a payload inside**, the publisher should decide about:
the two boot loaders (`iBSS.dev-hoolock.img4`, `iBEC.dev-hoolock.img4`) are patched copies of
Apple *development* iBoot, the device tree is Apple's, and the Nicotine image contains Apple's
WiFi/Bluetooth firmware and tuning data extracted from audioOS; the image's web UI and SSH have
no password (README-FIRST.txt says so); and only the `public` payload variant is free of the bench
network's WiFi credentials, so never bundle the bench image folder itself.

## The image folder (payload layout)

```
<image folder or payload>/
  MANIFEST                 payloads only: build number and SHA-256 of every file
  boot-linux.sh            the reference boot script
  homepod-config.sh        save / restore / status of a pod's settings
  README-FIRST.txt         payloads only: what this is, for a person who finds the folder
  config/                  bench folder only: one settings backup per pod (created by the script)
  img4/
    iBSS.dev-hoolock.img4, iBEC.dev-hoolock.img4     patched development bootloaders
    RestoreDeviceTree_b238aap.img4                   Apple's device tree
    RestoreTrustCache.img4                           empty trust cache
    RestoreKernelCache_m1n1-linux.img4               the Nicotine image (over 40 MB, changes per build)
```

The image is deliberately **not** in this repository. It gets into the app only at build time
(`BUNDLE_NICOTINE=1`) or by import, see above.

**Unit binding.** Every `.img4` in the folder carries the same IMG4 manifest: the generic A8
(CPID 0x7000) APTicket that SSHRD_Script ships and that this repo already vendors as
`scripts/apticket-0x7000.shsh`. It names one ECID, but after `gaster pwn` signature checks are off
and the patched bootloaders do not enforce it. The same folder has booted two different pods. So
nothing in the payload is tied to one unit. What *is* per pod: the settings backups in `config/`
(named by a 4-digit unit ID derived from the pod).

## Code map

| Where | What |
|-------|------|
| `Sources/HomePodRestoreCore/NicotineBooter.swift` | `NicotineLayout` (folder + validation), `NicotineBooter` (the sequence; `preflight` also verifies a MANIFEST), `NicotinePod` (reachability, version), `NicotineSettings` (runs homepod-config.sh; backup folder, `shouldAutoRestore`, `outcome`), `NicotineError`, `ErrorCatalog.nicotine` (plain-words explanations) |
| `Sources/HomePodRestoreCore/NicotinePayload.swift` | `NicotineManifest`, `NicotinePayload` (+ where its backups go), `NicotinePayloadLocator` (lookup order), `NicotinePayloadVerifier`, `NicotinePayloadImporter` (folder / zip → Application Support), `NicotineHash` |
| `Sources/HomePodRestore/AppModelNicotine.swift` | `NicotineUIState`, `nicotinePayload`, `bootNicotine(reveal:)`, `nicotineBlocker()`, `nicotineMissingTools`, `importNicotinePayload(from:)`, `refreshNicotinePod()`, save / restore settings, automatic restore |
| `Sources/HomePodRestore/Views/NicotineView.swift` | the page |
| `Sources/HomePodRestore/AppModel.swift` | stored state: `nicotine`, `nicotineFolderPath`, `nicotineAutoRestore`, `nicotineRevealToken`, the two tasks |
| `Sources/HomePodRestore/Views/RootView.swift` | sidebar section `.nicotine`; switches to it when `nicotineRevealToken` changes |
| `Sources/HomePodRestore/Views/DeviceCard.swift` | the two "Boot Nicotine (Linux)" entry points |
| `Tests/HomePodRestoreCoreTests/NicotineTests.swift` | sequence pinned against the script; fake-tool runs; parsing; settings script invocation |
| `Tests/HomePodRestoreCoreTests/NicotinePayloadTests.swift` | lookup order; MANIFEST parsing and verification (damaged, missing, unlisted); a damaged payload never reaches gaster; import of folder and zip; backups outside the payload; auto-restore decision and outcomes; optional real-payload check |
| `scripts/build-app.sh`, `scripts/bundle-tools.sh`, `scripts/make-nicotine-payload.sh` | `BUNDLE_NICOTINE=1`, tool bundling (warns when irecovery is missing), payload zip |

## Status when this was written

- The core (`NicotineBooter.swift`) compiles and its ten tests pass on Linux with Swift 5.10.1; the
  whole core suite still passes there apart from the three ProtoPod-fixture tests that need files
  on the Mac.
- The app-side files (`AppModelNicotine.swift`, `NicotineView.swift` and the edits to `AppModel`,
  `RootView`, `DeviceCard`) were written without a Mac toolchain: syntax-checked only, and
  `AppModelNicotine.swift` type-checked against stand-ins. **Not built on macOS, not run against a
  pod.** First things to check on hardware: that the app's `gaster`/`irecovery` are the ones the
  script uses on this Mac, the orientation (flip the pod right-side up once it is in DFU,
  before booting), the two-minute wait for the USB network, and password-less SSH with `BatchMode=yes`.

**Update, same day (self-contained app).** Added the payload lookup, MANIFEST verification,
import, bundling at build time, the tools prompt, backups outside the bundle and automatic restore.
The core side (21 Nicotine tests in two files, one of them optional) passes on Linux, including
against the real build-107 public payload as a folder and as a zip made by
`make-nicotine-payload.sh`; the bundling block of `build-app.sh` was exercised on Linux with a fake
payload (good, corrupted, missing). The SwiftUI side is again syntax-checked only, with
`AppModelNicotine.swift` type-checked against stand-ins. See "Fresh Mac checklist" for what that
leaves unverified.

## Ideas not done

- Passing the pod's ECID to gaster (`GASTER_ECID`, patched build) and `irecovery -i`, so that several
  pods could be connected. Needs the script to do it first.
- A countdown to flip the pod upright, as the SSH-ramdisk boot has.
- Download of a payload by URL (deliberately absent; see `payloadDownloadURL`).
- A universal (arm64 + x86_64) tool bundle, so Intel Macs need no installer either.


---

## Release boot loaders (from Apple's own files)

By default Nicotine boots on a pair of Apple **development** boot loaders
(iBoot-4076.30.43 from a prototype pod, patched by HoolockLinux's `hBootPatcher`).
Those must not be distributed. The same job can be done with the **release**
iBSS/iBEC inside Apple's audioOS 16.4 update (build 20L497), which anyone can
download from Apple — the same way the app already pulls 18.3 for a restore.

### How it is prepared

`scripts/prep-release-iboot.sh` (bundled into the app at
`Contents/Resources/prep-release-iboot.sh`) runs HoolockLinux's own tool
`remote_boot`, pinned to a known revision:

    download iBSS/iBEC from audioOS 16.4 (Apple CDN, ~1 MB)
    → decrypt on the HomePod itself (gaster, checkm8 DFU)
    → patch (hBootPatcher: sig-check, IORVBAR, AES)
    → wrap as IMG4 with the generic A8 IM4M

It writes `iBSS.img4` and `iBEC.img4` to `$RELEASE_IBOOT_OUT` (the app passes
this; from the terminal it defaults to `release-iboot/` next to the script).
First run on a Mac needs Homebrew `ipsw` (>= 3.1.719), `libirecovery` and `make`
(macOS ships GNU Make 3.81, which `remote_boot` refuses), plus the Xcode command
line tools and the pod in DFU. The script is the proven, hand-validated path; the
app does not re-implement the crypto.

`ReleaseIBootPreparer` (core) just runs that script, streams its output into the
boot log, and collects the two files. It runs under `UnlockCoordinator` like
every boot (the script does its own checkm8).

### How it boots

`NicotineBooter.Config.releaseIBoot: (iBSS, iBEC)?` — when set, those two files
are sent in place of the dev pair; **every later step is identical**
(`steps(for:releaseIBoot:)`). This is the app's equivalent of
`IBOOT_DIR=… ./boot-linux.sh`. `ReleaseIBootTests` pins that only the two
bootloader steps change.

Where the files live, per payload source (`AppModel.nicotineReleaseIBootDir`):

- **chosen folder** → its own `release-iboot/` (so the plain `boot-linux.sh`
  finds them too)
- **bundled / imported** (the folder is read-only or replaced wholesale) →
  `…/Application Support/HomePod Hospital/Nicotine Release iBoot/`

The Nicotine page's **Boot loaders** card prepares them and offers the toggle
"Boot with Apple release boot loaders" (on by itself once they are prepared;
persisted as `nicotineUseReleaseIBoot`). When off, or not prepared, the boot uses
the dev pair exactly as before.

### Not done yet (the fully self-contained version)

The preparer still shells out to `remote_boot`, which clones from GitHub and needs
Homebrew `ipsw`/`libirecovery`/`make`. A later step is to do the whole pipeline
natively in the app — it already has the HTTP-range downloader (used for the
donor ramdisk), `gaster` (for `decrypt`), `img4tool` (for the wrap) and the
`apticket-0x7000.shsh` IM4M; what is missing is a macOS build of `hBootPatcher`
bundled in. That would let a fresh Mac build release loaders with no Homebrew and
no network to GitHub, and the payload could then drop both dev files.
