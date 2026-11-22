# HomePod Restore Project — Full Technical Background

Prepared for Nic Splattstoesser (Nic's Fix) · 2026-11-14

This document maps the complete technical landscape of the 1st-gen HomePod
USB-restore project: the hardware, the manual restore chain, the HomePodRestore
macOS app, and the documented goals (chiefly SysCfg recovery for NAND swaps).
It synthesizes the staged project files with public reference material. Where a
fact comes from public sources it is cited; where it comes from the project's own
files that origin is named inline.

---

## 1. Apple HomePod 1st Gen Hardware (AudioAccessory1,1 / A1639)

### SoC — Apple A8 (T7000 / APL1011)
The 1st-gen HomePod is **AudioAccessory1,1**, built on the **Apple A8** — the same
SoC family found in the iPhone 6/6 Plus, iPad mini 4, iPod touch 6, and Apple TV
HD (AppleTV5,3). Per the TechInsights teardown, the A8 "was introduced in the
iPhone 6 and 6 Plus in 2014" and is fabbed by **TSMC on a 20 nm HKMG CMOS
process**. In iBoot's USB serial string the A8 reports **CPID 0x7000** (`t7000`);
the project code keys "is this an A8 HomePod?" off exactly that (`DeviceInfo.swift`:
`isA8 { cpid == 0x7000 }`). The board is **b238aAP**, **BDID 0x38 (56)**
(`DeviceInfo.swift`: `isHomePodBoard { bdid == 0x38 }`; the community `restorer.sh`
calls this "BoardID: 56").

The critical consequence: **A8 is checkm8-vulnerable**, and that bootrom bug is the
entire basis of the restore and SysCfg work (project doc *Free SysCfg Recovery
Route*).

### DRAM
SK hynix **H9CKNNNBKTCUSR** mobile SDRAM, stacked on top of the A8 in a
package-on-package (PoP) assembly (TechInsights teardown).

### NAND flash — 16 GB, the heart of the SysCfg problem
The teardown found **SK hynix H2JTDG8UD1CMR, a 128 Gb E2NAND3.0 chip = 16 GB**,
and notes that other HomePod units shipped a **Toshiba THGBX4G7D2LLDYC 16 GB NAND**
instead. This is the chip that fails/gets swapped in repair, and the chip that
carries SysCfg. It is a managed NAND (E2NAND / PPN-style) driven by Apple's ASP/ANC
flash stack, not a dumb raw flash.

Observed on-device NAND/disk layout over the SSH ramdisk
(`docs/homepod-nand-map.md`), read with `dd bs=1m` (512-byte reads return nothing —
needs large aligned blocks):

| device | size (observed) | contents |
|---|---|---|
| disk0 / disk0s1 | GB | main storage, **APFS, encrypted** |
| disk1 s1–s5 | TBD | not yet dumped — a SysCfg candidate |
| disk2 | 4 MB | **firmware / LLB+iBoot** — contains `Util_Find_SysCfg`, `Find_Fast_Scan` strings, BNCH/BORD boot nonce |
| disk3 | ~1 MB | **panic log** (the app's "Pull diagnostics" reads `/dev/rdisk3`) |
| disk4 | 0 B via bs=1m | special/unreadable with 1 MB reads |

Key finding: **SysCfg is not a plaintext block at a fixed offset.** disk2's LLB has
`Util_Find_SysCfg` + a "Fast Copy B" / wear-leveled scan — SysCfg lives in a
reserved, wear-leveled zone the firmware *scans* for. This is the "semi-hidden NAND
partition" tihmstar described, and it is why a NAND swap loses identity and why a
naive raw-offset write won't work.

### Debug / USB port
The teardown famously revealed a **hidden ~14-pin port on the underside** and 16 GB
of flash (MacDailyNews, Feb 2018; iFixit). In practice the restore workflow uses an
adapter on that underside port that presents the pod as a **USB device** to a Mac
(the app's user flow: "plug in a HomePod upside down → adapter → USB → power").
That exposes DFU/recovery/restore USB modes (`DeviceInfo.swift` maps product IDs:
DFU 0x1227, recovery 0x1280–0x1283, restore/usbmux 0x1200–0x12FF). A community
hack has also adapted that same debug port to carry USB audio (AppleInsider /
MacDailyNews, Sept 2024) — unrelated to restore, but confirms the port's
versatility.

The HomePod is **headless** — there is no screen and no console, so the iPhone/iPad
"purple-mode, type into a DCSD console" workflow does not map directly; everything
must be driven over USB from the Mac (project doc *Free SysCfg Recovery Route*).

---

## 2. The Manual Restore Process

### checkm8 (via gaster)
**checkm8** is an unpatchable **bootrom (SecureROM) exploit** affecting A5–A11
(theapplewiki.com/wiki/checkm8). Because it lives in mask ROM it cannot be fixed by
a software update, and it lets you boot unsigned ("untrusted") images on the A8
HomePod. The project uses **gaster** (0x7ff's checkm8 implementation): `gaster pwn`
enters the exploit, `gaster reset` resets USB. Success is detected by the literal
string **"Now you can boot untrusted images."** (used as the gate in `RestoreJob`,
`SSHRDBooter`, and the community `restorer.sh`).

### idevicerestore — the actual restore
A full restore is, at its core:

```
gaster pwn → gaster reset → idevicerestore -d -e -y -i <ECID> -C <cache> <ipsw>
```

(`README.md`, `RestoreJob.swift`). `-e` erases, `-C` points at a shared unpacked
root-filesystem cache so parallel restores don't re-extract. The restore pushes
iBSS/iBEC/ramdisk/kernelcache, then the root FS, over USB.

### The IPSW-building chain (tihmstar + d235j tools)
A HomePod IPSW is not downloadable ready-made; it is **built** from two Apple
sources:

- a **HomePod OTA** (AudioAccessory1,1) — the actual audioOS payload, and
- the matching **Apple TV HD (AppleTV5,3) IPSW** — the **donor** that supplies a
  restore ramdisk the headless pod can boot.

The toolchain (installed from the **`d235j/ios-restore-tools` Homebrew tap**, mostly
`--HEAD`; see `setup-tools.sh`):

- **tihmstar's `makeipsw.sh`** — stitches the HomePod OTA + Apple TV donor ramdisk +
  `firmware_keys.zip` into a flashable `.ipsw`.
- **tihmstar's `ra1nsn0w`** — boots/patches a custom boot chain over checkm8;
  patches iBEC and the kernel (`--kpatch-always-get-task-allow`,
  `--kpatch-codesignature`, etc.). Used both in makeipsw and in the app's legacy
  ramdisk booter.
- **`img4tool` / `img4` / `iBoot64Patcher` / `tsschecker` / `ldid` / `irecovery` /
  `binrider`** — image (un)wrapping, iBoot patching, APTicket fetching, signing,
  and recovery-mode I/O.
- **David Ryskalczyk (d235j)'s `ios-restore-tools`** — the fork of libimobiledevice
  / libirecovery / idevicerestore that actually understands HomePods. The guide
  pins **idevicerestore @ commit `d2e1c4f`** and removes the tap's own
  idevicerestore (wrong version for HomePods), plus applies a `sed` fix for the
  `irecv_init` undeclared error with newer libirecovery (`setup-tools.sh`).

The whole effort is built on the **UnbendableStraw/homepod-restore** guide and
credits **tihmstar, d235j, 0x7ff, and libimobiledevice** (`README.md`). The
breakthrough that software-bricked HomePods could be revived came from the
tihmstar/david community work (r/HomePod, Aug 2024).

### Why only 18.3 (22K557) works reliably
This is a **code-signing-window** problem, not a tooling limitation. A normal
`idevicerestore` must get Apple's TSS server to **personalize (sign) the build for
this specific device+nonce**; Apple only signs a small set of current builds.
**audioOS 18.3 (22K557)** is the build the project ships prebuilt from nicsfix.com
and treats as the known-good target. The community `restorer.sh` encodes exactly
this failure mode: when the log shows *"This device isn't eligible for the
requested build"* it tells the user *"This IPSW is no longer signed by Apple, you
will need a newer IPSW."* When Apple rotates the signing window, the working build
moves — hence the app's "Build your own" feature (pull whatever HomePod OTA is
currently signed, pair it with the Apple TV donor, rebuild). It also shows Apple's
live signing status from **ipsw.me** so Nic can see which builds are still signable.

Note the distinction the SysCfg booter relies on: **checkm8 boots unsigned images,
so a generic per-chip APTicket is enough for ramdisk boot** — no live TSS signature
needed. That is why ramdisk boot keeps working on "dropped" builds even though a
full `idevicerestore` of that same build would fail (`SSHRDBooter`/`GasterRamdiskBooter`
comments).

---

## 3. The HomePodRestore App

A friendly macOS (13+) SwiftUI app that wraps the entire CLI chain. Nothing has run
against real hardware yet for the newer SysCfg/ramdisk paths (`README.md`: "Not yet
verified on hardware"); the restore path mirrors the proven community flow.

### Architecture
Swift Package, cleanly split so the logic is testable on Linux too (`Package.swift`,
`README.md` Layout):

- **`HomePodRestoreCore`** — Foundation-only library (builds & unit-tests on Linux):
  - `RestoreJob.swift` — gaster + idevicerestore orchestration; `UnlockCoordinator`
    actor serializes checkm8 across pods.
  - `RestoreProgress` / `ErrorCatalog` — turn raw logs into phases, progress, and
    plain-English diagnoses.
  - `FirmwareCatalog` / `FirmwareLibrary` / `IPSWBuilder` / `ZipArchive` /
    `Downloader` — ipsw.me + nicsfix.com manifest, local IPSW handling, the
    makeipsw pipeline, a ZIP/ZIP64 reader that works over **HTTP range requests**,
    resumable downloads.
  - The SysCfg/ramdisk stack (below).
- **`HomePodRestore`** — the SwiftUI app + an IOKit USB monitor (`AppModel.swift`,
  Views).

### USB detection
`USBMonitor` (IOKit) emits `ConnectedDevice` values keyed by **USB location ID**
(stable per physical port, so a pod keeps identity across DFU→recovery→restore).
`IBootSerial` parses the iBoot serial string (CPID/CPRV/BDID/ECID/SRTG/PWND), which
drives A8/board checks, DFU detection, and ECID targeting. One card = one USB port.

### Firmware: download, import, build
- Downloads the prebuilt **18.3** IPSW from nicsfix.com (resumable, SHA-256
  checked); imports any local `.ipsw`; shows ipsw.me signing status.
- **Build-your-own:** lists signed HomePod OTAs, pairs each with the matching
  Apple TV HD IPSW, and — cleverly — pulls **only `BuildManifest.plist` + the
  restore ramdisk** out of the ~5 GB Apple TV IPSW using HTTP range requests
  (~80 MB instead of 5 GB), then runs `makeipsw.sh` as admin.

### Restore execution & batch provisioning
- One click per card runs the gaster→idevicerestore flow with a progress bar and
  plain-English steps (`RestoreJob`).
- **Several pods at once:** jobs target by ECID; the checkm8 step is serialized
  (`UnlockCoordinator`); the root FS is unpacked once into a shared cache so
  parallel `idevicerestore` runs don't race.
- **Batch station:** "Restore automatically when plugged in" (`autoRestore`) kicks
  off a restore on any A8 pod that enters DFU, with a 15-minute guard so it won't
  re-restore the same ECID (`AppModel.autoStartIfPossible`).
- **Multi-pod gaster patch:** stock gaster grabs the first DFU device; the project's
  `gaster-ecid.patch` adds `GASTER_ECID=0x…` so a specific pod is targeted. Without
  it, only one pod may be in DFU at a time (enforced by `AppModel.blocker`).

### Health check
- **Quick check** (≈30 s): USB link speed, A8 chip, b238 board, checkm8 unlock —
  isolates adapter/cable/port problems.
- **Boot test** (`idevicerestore -z`): boots the restore ramdisk and stops, erasing
  nothing — a non-destructive A8/RAM test.
- **NAND** is judged during a real restore (NAND wait time, "Waiting on NAND",
  NVRAM timeouts, Disk Failure) — `HealthView` / `HealthChecklist`.
- Every known Troubleshooting message maps to a title/explanation/"what to try",
  with hardware failures flagged; "Copy support info" makes a Discord-ready report
  with ECID redacted.

### The SSH-ramdisk pipeline (how it gets a shell on the pod)
This is the backbone of the SysCfg work. A **shell-capable ramdisk** is booted on
the pod over checkm8, then SSH (dropbear) is reached over USB.

Boot sequence, faithful to the proven d235j flow (`SSHRDBooter`):
```
gaster pwn → gaster reset →
irecovery -f iBSS → iBEC → logo(+setpicture) →
ramdisk(+ramdisk) → devicetree(+devicetree) →
trustcache(+firmware) → kernelcache → (flip window) → bootx
```
then `iproxy <localPort> 22` forwards the pod's SSH to localhost and the app logs in
as **root / password `alpine`** (via `sshpass`, since dropbear uses password auth).
Boot-args for the read/write variant deliberately **drop** the destructive restore
args (`nand-enable-reformat=1 -restore`) so a SysCfg read/write never reformats NAND.

Three boot modes (`AppModelSysCfg.SysCfgBootMode`, selected in UI):
- **preBooted** — the tech booted the pod out-of-band (proven d235j SSHRD); the app
  just connects + auto-forwards iproxy. **Works today.** (`PreBootedBooter`)
- **sshrd** — the app drives the d235j `sshrd.sh boot` sequence natively (no
  terminal, no `read -p` prompts), from a built `sshramdisk/` set. (`SSHRDBooter`)
- **legacy** — old in-app gaster + ra1nsn0w path; kept only as an unreliable
  fallback. (`GasterRamdiskBooter`)

Two ramdisk *builders* exist: `SSHRamdiskBuilder` + `build-ssh-ramdisk.sh` (pull the
Apple TV donor ramdisk, inject a dropbear overlay, repack as `rdsk` img4 — admin
step), and `SSHRDRamdiskBuilder` which drives the heavier d235j `sshrd.sh ota`
create pipeline.

The transport (`SSHRamdiskTransport`) wraps pod output in base64 + markers so binary
survives SSH banners/stderr, strips ANSI, and extracts IORegistry hex properties.
`DiagnosticsController` adds a **read-only, ship-early** feature: pull the panic log
(`dd if=/dev/rdisk3 bs=1m`) + an `ioreg -l` snapshot + a read-only SysCfg
write-facility probe — no writes, no brick risk.

### Current SysCfg READ capability — SOLVED
**SysCfg read is fully proven on hardware** (`docs/homepod-nand-map.md`,
`SYSCFG_WRITE_FINDINGS.md`). The ramdisk exposes SysCfg live via the IORegistry:
```
ioreg -r -c AppleDiagnosticDataAccessReadOnly -l   → property "AppleDiagnosticDataSysCfg"
```
The real capture is **131072 bytes (128 KB)**, signature **`gfCS`** (the "SCfg"
FourCC stored reversed, matching the **Reviv** carver's convention). The app's
reversed-key parser (`SysCfg.swift`) extracts, from a known good pod:
serial **SERIAL000001**, Wi-Fi **02:aa:bb:cc:dd:01**, BT …:02, Eth …:03,
Model **MQHW2**, Region **LL/A**, RModel **A1639** — all validated against the
on-device dump and the unit sticker.

Design safety: the restore path writes the **raw bytes verbatim** and never
re-serializes from parsed fields, so correctness never depends on the parser being
byte-perfect. The parser exists only to *show* the human the serial/MACs and
sanity-check a dump. The write path is built, read-back-verifies, and **refuses to
write** until the on-device "sink" is validated (`SSHRamdiskTransport.hasValidatedSink`
rejects the placeholder `syscfg_write`).

---

## 4. Documented Goals

### Batch provisioning — largely DONE
Multiple pods per station, ECID-targeted jobs, serialized checkm8, shared FS cache,
and auto-restore-on-plug already exist (section 3). The remaining friction is the
single-pod limit without the patched gaster, which the `GASTER_ECID` patch removes.

### Newer firmware versions — PARTIALLY DONE
"Build your own" + the ipsw.me signing view already let Nic track and build whatever
HomePod OTA Apple currently signs, pairing it with the Apple TV donor. The remote
`manifest.json` on nicsfix.com lets him change the recommended build with no app
update. The open edge is that each new audioOS may shift strings/offsets the log
parser and (especially) the SysCfg-write kernel RE depend on.

### NAND health checks — PARTIALLY DONE
Restore-time NAND signals ("Waiting on NAND", NVRAM timeouts, Disk Failure, NAND
wait seconds) are parsed and surfaced, and the read-only diagnostics pull (panic log
+ ioreg) ships with no brick risk. A dedicated pre-swap NAND health probe is not yet
a first-class feature.

### SysCfg recovery for NAND replacements — THE BIG GOAL (read solved, WRITE open)
The core business problem: a **NAND swap fails activation** because SysConfig
(serial, Wi-Fi/BT MAC) lived on the original chip and is missing from the new one.
The target is "recover SysCfg off the old chip, write it to the new chip" — the same
job the $200 hardware NAND programmers do, but in software over checkm8 (project doc
*Free SysCfg Recovery Route*). For a dead original chip, **Reviv** can carve
serial/Wi-Fi/BT out of a corrupted dump. The read side is done (section 3). The
**write side is the one unsolved piece**, and the RE history is important so nobody
repeats a dead end:

**What was tried and ruled out (`SYSCFG_WRITE_FINDINGS.md`, `docs/syscfg-write-re.md`):**
1. `setProperties({"AppleDiagnosticDataSysCfg": blob})` on the ReadOnly diagnostics
   node reaches the kernel write path but returns **0xe00002c4 (kIOReturnNotWritable)**
   — because (a) ASPStorage forces read-only when rooted on a ramdisk, and (b) even
   after unlocking that via `setProperties({"ASPSetWritable": true})` on the
   **ASPStorage** node (which does succeed), the diagnostics node's **vtable slot 44
   = a hardcoded NotWritable stub** in the `…ReadOnly` class. The write refusal is
   **by design in the ReadOnly class**, independent of NAND writability.
2. **ASPUserClient** is a lifecycle-only user client (no externalMethod, no mappable
   memory) — no userspace write path there either.
3. A later note flagged the planned **base→stage→commit `setProperties` kernel cave
   as invalid/unsafe on 18.3** (type-confusion/brick risk) and said **do not flash
   it**.

**The two live candidate paths forward:**
- **A) `AppleEffaceableStorageUserClient`** (`SYSCFG_WRITE_FINDINGS.md`, the newest
  RE). SysCfg is stored as an **effaceable locker**; this kext exposes a 12-selector
  dispatch with **`GetLocker`(5) / `SetLocker`(6) / `EffaceLocker`(7) /
  `GenerateNonce`(10)**. `SetLocker` does container-safe generation/checksum/commit —
  a clean, round-trip-verifiable, mostly-userspace write that needs **at most one
  tiny kernel patch** (`clientHasPrivilege("SecureRoot")` → true) if SysCfg is a
  *protected* locker. Open items to pin on the bench (read-only, safe first): the
  exact SysCfg locker `type_id`, its class (private/protected/normal), and the
  `IOConnectCallMethod` arg shape.
- **B) A writable-kext DIAGS ramdisk** (`SSHRD_Script/diags_boot.sh`). Boot an **11.2
  DIAGS** ssh-ramdisk with a **patched kernelcache** (`amfi_get_out_of_my_way=1
  cs_enforcement_disable=1`), then `kextutil` the **writable
  `AppleDiagnosticDataAccess.kext`** (the non-ReadOnly RW class) and run a
  `syscfg_write` tool. This sidesteps the ReadOnly-stub problem by instantiating the
  real read-write node.

**Do-not-brick rules (consistent across the docs):** never `SetLocker`/write before a
clean `GetLocker`/read on that exact pod; always same-bytes round-trip on a
known-good pod (read own SysCfg → write it back → reboot → re-read → serial
unchanged) before any new-chip write; keep every pod's original 128 KB blob saved.

---

## 5. One-line status summary

| Capability | Status |
|---|---|
| USB restore (gaster + idevicerestore) | Working (community-proven); wrapped in-app |
| Build-your-own IPSW (makeipsw + Apple TV donor) | Implemented (HTTP-range donor pull) |
| Multi-pod / batch / auto-restore | Implemented (ECID-targeted, serialized checkm8) |
| SSH ramdisk boot + shell | Proven (preBooted today; in-app SSHRD driven) |
| Read-only diagnostics (panic log, ioreg) | Implemented, no brick risk |
| **SysCfg READ** | **Solved on hardware** (128 KB `gfCS`, ioreg) |
| **SysCfg WRITE** (the NAND-swap goal) | **Open** — two candidate paths: EffaceableStorage `SetLocker`, or writable-kext DIAGS ramdisk |

### Key file references (all absolute, under /mnt/user-data/uploads/homepod/)
- Strategy / RE: `Free SysCfg Recovery Route for HomePod NAND Swaps (checkm8).md`,
  `SYSCFG_WRITE_FINDINGS.md`, `HomePodRestoreApp/docs/syscfg-write-re.md`,
  `HomePodRestoreApp/docs/homepod-nand-map.md`,
  `HomePodRestoreApp/docs/ssh-ramdisk-runbook.md`
- Core: `HomePodRestoreApp/Sources/HomePodRestoreCore/{SysCfg,SysCfgRamdiskTransport,
  SysCfgSession,SSHRDBooter,SSHRamdiskBuilder,RestoreJob,DeviceInfo}.swift`
- App: `HomePodRestoreApp/Sources/HomePodRestore/{AppModel,AppModelSysCfg}.swift`,
  `Views/{SysCfgSheet,HealthView}.swift`
- Scripts: `HomePodRestoreApp/scripts/{build-ssh-ramdisk,setup-tools}.sh`,
  `SSHRD_Script/{README.md,diags_boot.sh}`, `restoregui/HomePodRestore/restorer.sh`
