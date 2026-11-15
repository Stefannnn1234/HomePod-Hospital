# HomePod restore project: file inventory

Scope: all 26 staged files under `/mnt/user-data/uploads/homepod/` were read in full (about 5,200 lines). Nothing was built or run. Folders that were not staged are listed at the end from the task description only.

## Headline findings

1. **SysCfg read is done and proven on hardware; SysCfg write is not solved, and the docs disagree about it.** `HomePodRestoreApp/docs/syscfg-write-re.md` ends with "WRITE PATH SOLVED" (a kernelcache patch). The newer `SYSCFG_WRITE_FINDINGS.md` says that same patch is invalid and unsafe and must not be flashed, and moves to a different mechanism (`AppleEffaceableStorageUserClient` GetLocker/SetLocker) that has not been tried on a pod yet. The older doc has no note pointing at the newer one.
2. **The app cannot write SysCfg today, by design.** Every booter defaults `sinkCommand` to the placeholder `"syscfg_write"`, nothing in the app overrides it, and `SSHRamdiskTransport.hasValidatedSink` refuses that placeholder. The "Restore SysCfg…" UI is fully wired but will always stop with the "write mechanism isn't validated yet" message.
3. **There are three write approaches in the files, and only two are documented.** (a) setProperties kernel patch (17.5, shelved), (b) Effaceable user client (18.3, current plan), (c) `SSHRD_Script/diags_boot.sh`: boot an 11.2.5 DIAGS kernel and load the writable `AppleDiagnosticDataAccess` kext. No staged doc says whether (c) was tried or what happened.
4. **Kernel version mismatch to keep in mind.** The app builds and boots the SSHRD ramdisk for **17.5** (`sshrd.sh ota 17.5`, hard-coded default). The newest reverse-engineering addresses and the 12-selector table are from the **18.3** kernelcache. The selector table needs confirming against whichever kernel the ramdisk actually boots.
5. **Legacy booter default boot-args include the destructive restore args.** `GasterRamdiskBooter.Config` defaults to `rd=md0 debug=0x2014e -v wdt=-1 nand-enable-reformat=1 -restore`, while its own comment and the runbook both say the SSH variant deliberately drops `nand-enable-reformat=1 -restore`. `AppModelSysCfg.makeBooter` (legacy case) does not override it. Only the "Legacy (ra1nsn0w)" mode is affected, but it is a code/doc contradiction on a NAND-safety setting.
6. **Several docs are stale** (README, ssh-ramdisk-runbook, parts of homepod-nand-map); details per file below.

## 1. Planning and research docs

| File | What it is | State |
|---|---|---|
| `Free SysCfg Recovery Route for HomePod NAND Swaps (checkm8).md` | The original plan, dated Nov 12, 2026 | Complete as a plan; its "next step" is now done |
| `SYSCFG_WRITE_FINDINGS.md` | Newest write-side RE on audioOS 18.3 (22K557) and the revised plan | Current; RE complete, nothing tested on hardware |
| `HomePodRestoreApp/docs/syscfg-write-re.md` | Chronological RE log of the write path on 17.5 | Superseded in its conclusion; no pointer to the newer doc |
| `HomePodRestoreApp/docs/homepod-nand-map.md` | NAND device map observed from the SSH ramdisk, plus feature status | Partly stale; disk1 and disk4 still open |
| `HomePodRestoreApp/docs/ssh-ramdisk-runbook.md` | Bench runbook for the first hardware run | Stale; describes the legacy ra1nsn0w flow as the default |

### `Free SysCfg Recovery Route for HomePod NAND Swaps (checkm8).md` (64 lines)
- Argues the free route is viable: A8 is checkm8-vulnerable, MagicCFG Reloaded and PurpleEditor are prior art, and a NAND swap fails activation because SysCfg (serial, Wi-Fi MAC, BT MAC) lived on the old chip.
- Catch: those tools need a Diags image and carry per-device tables; none exists for AudioAccessory1,1 / B238aAP, and the pod is headless.
- Proposed route: boot a shell/SSH ramdisk on the existing gaster + ra1nsn0w chain and reach SysCfg through `AppleNANDConfigAccess` / `AppleDiagnosticDataAccessReadOnly` (`AppleDiagnosticDataSysCfg`). For a dead old chip, carve the dump with Reviv.
- De-risk step: non-destructive read on a known-good pod first.
- Relations: this is the brief that the SysCfg code, the ramdisk builders and the other docs implement. References `makeipsw.sh` and the 18.3 IPSW in the unstaged `homepodstuff/`.

### `SYSCFG_WRITE_FINDINGS.md` (147 lines)
- States READ is solved: 128 KB (131072-byte) blob extracted and decoded (serial, MLB, model MQHW2, region LL/A, 3 MACs).
- Proves the setProperties base, stage, commit patch is a dead end on 18.3: the write is stubbed at two vtable levels (+0x160 and +0x540), stage/commit expect a request object so passing the dictionary is type confusion, and no data-injection path exists. Says it was never tested on hardware. Artifact `kc-syscfg-patch-183.py` kept for reference, marked do-not-use.
- New mechanism: `AppleEffaceableStorageUserClient`, `externalMethod` at `0xfffffff0066fa99c`, 12 selectors. GetLocker = 5, SetLocker = 6, EffaceLocker = 7, lockerSpace = 8, GenerateNonce = 10. Raw getBytes/setBytes/setLockerWithID (1, 2, 11) are gated on `PE_i_can_has_debugger`; locker calls carry a "trusted" flag from `clientHasPrivilege("SecureRoot")`.
- Internal inconsistency: the first half guesses selectors Get=0, Set=1; the "UPDATE" section corrects that to 5 and 6. The UPDATE table is the authoritative one.
- Open items: the SysCfg locker `type_id` and its class (normal / protected / private). Protected would need a one-instruction `clientHasPrivilege` patch; private would need raw setBytes.
- Revised plan: GetLocker probe (read-only), discover type_id, SetLocker, with a same-bytes round-trip before any donor write. Ends with three do-not-brick rules.
- Relations: supersedes the final section of `syscfg-write-re.md`. The app's write probe (`SSHRamdiskTransport.writeProbeCommand`) already lists the `AppleEffaceableStorage` ioreg node, but no code calls the user client. References `/mnt/user-data/uploads/SSHRD_Script/syscfg.bin` (not staged).

### `HomePodRestoreApp/docs/syscfg-write-re.md` (177 lines)
A log that reverses itself several times. In order:
- Hypothesis: write via `setProperties({"AppleDiagnosticDataSysCfg": blob})`, entitlement `com.apple.system.diagnostics.iokit-properties`.
- Hardware result: `syscfgset write` returns `0xe00002c4` (not writable).
- "SOLVED, the unlock": `setProperties({"ASPSetWritable": true})` on `ASPStorage` clears the ramdisk read-only lock. Hardware: unlock returns success, SysCfg write still fails.
- "Second wall": the `...ReadOnly` class has a hard-coded NotWritable stub.
- ASPUserClient analysed as a memory-map interface, then corrected: it is lifecycle-only, no write path.
- "Final conclusion": every userspace IOKit avenue is closed on 17.5.
- Last section "WRITE PATH SOLVED, kernelcache patch (tools/kc-syscfg-patch)": trampoline the stub into a 72-byte cave calling base setProperties, stage, commit. **This is the patch the newer findings doc says not to flash.**
- Also inconsistent with itself and the newer doc on which vtable slot is setProperties (slot 43/44 vs +0x160).
- References tools not staged: `tools/syscfgset` (probe / read / write / writeunlock), `tools/kc-syscfg-patch/patch.py`.
- Still-valid content: the read path, the ASPStorage unlock, and the tvOS build notes for on-pod tools (link only CoreFoundation, resolve IOKit via dlsym, deploy to a tmpfs at `/mnt1`).

### `HomePodRestoreApp/docs/homepod-nand-map.md` (50 lines)
- Device table: disk0/disk0s1 encrypted APFS; disk1 s1 to s5 not yet dumped; disk2 4 MB firmware (LLB/iBoot, contains `Util_Find_SysCfg`); disk3 about 1 MB panic log; disk4 returns 0 bytes with 1 MB reads. Raw reads need `dd bs=1m`.
- SysCfg read confirmed via `ioreg -r -c AppleDiagnosticDataAccessReadOnly -l`, 131072 bytes, signature `gfCS`.
- Says SysCfg is not a plaintext block on disk0/2/3 and lives in a wear-leveled zone the firmware scans for.
- Describes the diagnostics feature and the three boot modes (preBooted, sshrd, legacy); this part matches the code.
- Stale or contradictory: one bullet says the reversed `gfCS` block is "not yet located on this device" while the section above says the capture has that signature. Names `AppleNANDConfigAccess` as the write candidate, which later RE ruled out.
- Contains one real unit's serial and MAC addresses (so do both findings docs).

### `HomePodRestoreApp/docs/ssh-ramdisk-runbook.md` (68 lines)
- Prerequisites, build step, "confirmed vs open" list, read proof, write-by-construction.
- Stale against the code:
  - Treats `GasterRamdiskBooter` (gaster, tsschecker APTicket, ra1nsn0w) as the default; the code now calls that "legacy, known-unreliable" and defaults to the SSHRD irecovery chain.
  - Says `dumpCommand` is an open placeholder (`syscfg_dump`); the code default is now the proven ioreg query.
  - Says Setup's builder install provides `iproxy` and `sshpass`; `setup-tools.sh` installs iproxy but never sshpass.
  - Says boot-args drop `nand-enable-reformat=1 -restore`; the code default still has them (headline finding 5).
- Says the write is "trustworthy by construction"; true for the verbatim-write and read-back logic, but there is no working sink.

## 2. App: package and README

### `HomePodRestoreApp/Package.swift` (49 lines)
- Swift tools 5.9, macOS 13+. Targets: `HomePodRestoreCore` (Foundation-only, builds on Linux), `HomePodRestoreCoreTests` (with a `Fixtures` resource), and on macOS the `HomePodRestore` executable linking IOKit and AppKit. No external package dependencies.
- Complete. The Tests directory is not staged.

### `HomePodRestoreApp/README.md` (97 lines)
- Covers restore, multi-pod batch, firmware download/import, build-your-own IPSW, health check, error catalog, build instructions, the `GASTER_ECID` gaster patch, the remote manifest at nicsfix.com, file locations, source layout.
- Stale: no mention of SysCfg, diagnostics pull, the SSH ramdisk or boot modes. The layout list omits every SysCfg/SSHRD source file. The closing section says nothing has run against a real HomePod, while the docs record on-device SysCfg reads and write attempts.
- Names files not staged: `RestoreProgress.swift`, `ErrorCatalog.swift`, `FirmwareCatalog.swift`, `FirmwareLibrary.swift`, `IPSWBuilder.swift`, `ZipArchive.swift`, `Downloader.swift`, `scripts/build-app.sh`, `scripts/bundle-tools.sh`, `scripts/patches/gaster-ecid.patch`, `Distribution/manifest.json`.

## 3. App core library (`Sources/HomePodRestoreCore/`)

### `SysCfg.swift` (272 lines): data model, parser, transport protocol, job
- `SysCfgField`, `SysCfgData` (keeps `rawBytes` verbatim), `SysCfgParser`, `SysCfgTransport` protocol, `SysCfgError`, `FakeSysCfgTransport`, `SysCfgJob` (modes `.read` and `.restore(blob, confirmed)`).
- Restore path: refuses unless confirmed, signature present and SrNm/WMac/BMac all found; writes the blob verbatim; reads back and byte-compares.
- State: complete and working for read. Parser is display-only by design. Issues found:
  - `mlbSerial` looks up `MLBN`, but `MLBN` is not in `knownTags`, so it is always nil (the UI row never shows). `RMd#` is parsed but has no accessor.
  - Values are read until the first NUL byte. A MAC containing a `00` byte is shown truncated, and a MAC starting with `00` is treated as missing, which would wrongly reject a good dump for restore.
  - `macString` doc says "exactly 6 bytes" but accepts 1 to 8.
  - Only the first occurrence of each reversed tag is used.

### `SysCfgRamdiskTransport.swift` (248 lines): SSH transport
- `SSHRamdiskTransport` implements `SysCfgTransport` and `RamdiskShell`. Read: runs `ioreg -r -c AppleDiagnosticDataAccessReadOnly -l`, strips ANSI, extracts the `AppleDiagnosticDataSysCfg` hex value. Generic binary dump: markers plus base64. Auth: `sshpass` with root / `alpine` to 127.0.0.1:2222, host-key checks off.
- Write: gated by `hasValidatedSink`; if ever enabled it sends the blob as base64 in the command line piped to `sinkCommand`.
- `writeProbeCommand`: read-only enumeration of `AppleNANDConfigAccess`, `AppleEffaceableStorage`, candidate CLIs, `/usr/local/bin`, `/usr/sbin`.
- State: read complete and proven; write is a gated stub. Stale header comments: says the blob is "hundreds of bytes to a few KB" (it is 128 KB, so the write would put about 175 KB of base64 on a command line, untested) and says dump/sink are both placeholders.

### `SysCfgSession.swift` (287 lines): phases, booter protocol, legacy booter, controller
- `SysCfgPhase`, `BootedPod`, `RamdiskBooter` protocol, `FakeRamdiskBooter`.
- `GasterRamdiskBooter` (the legacy path): gaster pwn/reset, generic bundled APTicket or tsschecker-fetched ticket, `ra1nsn0w -t … -r … -b …`, iproxy. Supports `GASTER_ECID`.
- `SysCfgController.read` / `.restore`: boot, run `SysCfgJob`, teardown.
- State: complete. Issues: the boot-args default (headline finding 5); header comment still says the dump command is unproven; `restore` reports the `.verifying` phase before the write starts (cosmetic).

### `SSHRDBooter.swift` (443 lines): the current boot pipeline plus diagnostics
- `RamdiskShell` protocol.
- `PreBootedBooter`: pod already booted; optionally starts iproxy, checks `echo hpr-ready`.
- `SSHRDLayout`: finds an SSHRD_Script checkout (`~/SSHRD_Script` or app support), its `Darwin/` tools and `sshramdisk/`; requires iBSS, iBEC, ramdisk and kernelcache `.img4`.
- `SSHRDBooter`: waits for DFU, gaster pwn/reset, then irecovery sends iBSS, iBEC, logo, ramdisk, devicetree, trustcache, kernelcache, a 12-second "flip the HomePod upright" countdown, `bootx`, iproxy, waits up to 90 s for dropbear.
- `DiagnosticsController` / `DiagnosticsBundle`: read-only pull of the panic log (`dd if=/dev/rdisk3 bs=1m`), `ioreg -l`, and the write probe.
- `SSHRDRamdiskBuilder`: runs `sshrd.sh ota 17.5` in the checkout (pod must be in DFU).
- State: complete; the NAND map doc records it working on a live pod. Limits: does not target by ECID (no `GASTER_ECID`, no `irecovery -i`), so one pod in DFU at a time; `killStaleForwarders` runs `killall iproxy`, which kills unrelated forwards too.

### `SSHRamdiskBuilder.swift` (237 lines): in-app ramdisk builder for the legacy path
- Fetches only the restore ramdisk out of the Apple TV HD donor IPSW via HTTP range reads, downloads `firmware_keys.zip`, then runs `scripts/build-ssh-ramdisk.sh` as admin through `osascript`, tailing the log. Output cached at `…/HomePod Restore/SSHRamdisk/sshrd-<build>.img4`.
- State: complete, but it feeds only the legacy `GasterRamdiskBooter`. Its header still calls key, overlay and boot args "unproven". Depends on unstaged `IPSWBuilder`, `ZipDirectory`, `HTTPRangeSource`, `AppPaths`, `Links`, `ProcessRunner`.

### `RestoreJob.swift` (331 lines): the normal restore
- `UnlockCoordinator` actor (one checkm8 at a time, shared with the SysCfg booters).
- `RestoreJob` kinds: restore, quickCheck (unlock only), bootTest (`idevicerestore -z`). Up to 3 `gaster pwn` attempts, then `idevicerestore -d -e -y -i <ECID> -C <cache> <ipsw>`, with a stall watchdog, log parsing, per-job log file.
- State: complete. No SysCfg or NAND code; NAND health is inferred from restore log lines by the unstaged parser.

### `DeviceInfo.swift` (137 lines)
- `DeviceMode` from USB product ID, `IBootSerial` parser (CPID, BDID, ECID, SRTG, PWND), `ConnectedDevice` with port label and USB speed. A8 = CPID 0x7000, HomePod board = BDID 0x38.
- State: complete. A pod booted into the SSH ramdisk falls under `.restore` mode and has no iBoot serial, which is why the app has separate "already booted" entry points.

### `ToolLocator.swift` (174 lines)
- `Tool` enum (8 tools), `ToolStatus`, lookup order: app bundle `Resources/bin` (if CPU matches `ARCHS`), then `~/Library/Application Support/HomePod Restore/bin`, then search paths. Warns if idevicerestore is not commit `d2e1c4f` or gaster lacks `GASTER_ECID`.
- State: complete for restore/build. `iproxy` and `sshpass` are not in the enum, so the Setup screen cannot report them; they are found ad hoc in `AppModelSysCfg`.

## 4. App UI layer (`Sources/HomePodRestore/`)

### `AppModel.swift` (474 lines)
- Main observable model: devices and per-port slots, jobs and history, tool status, firmware library/downloads/shared cache, IPSW builder, auto-restore, notifications, support report.
- Holds the SysCfg/diagnostics/SSHRD-build state. Default boot mode is `.sshrd` if an SSHRD checkout is found, else `.preBooted`; persisted in UserDefaults.
- State: complete.

### `AppModelSysCfg.swift` (536 lines)
- `SysCfgBootMode` (preBooted / sshrd / legacy) and UI state structs.
- Actions: `readSysCfg(on:)`, `restoreSysCfg(on:from:)`, `pullDiagnostics(on:)` for DFU devices; `readSysCfgBooted()`, `restoreSysCfgBooted(from:)`, `pullDiagnosticsBooted()` for an already-booted pod (ECID 0); `buildSSHRDRamdisk()`; `buildSSHRamdisk(_:)`; `saveDiagnostics` (writes paniclog.bin, ioreg.txt, syscfg-write-probe.txt, notes.txt); `makeBooter(ecid:)`.
- Restore validates the dump (signature plus essentials) before touching hardware.
- State: complete for read and diagnostics; restore is wired but blocked by the sink gate. Small inconsistency: `makeBooter`'s preBooted case looks for sshpass/iproxy on the app paths only, while `preBootedController()` also falls back to the SSHRD `Darwin/` folder.
- The callers of `readSysCfg(on:)`, `restoreSysCfg(on:from:)`, `pullDiagnostics(on:)`, the boot-mode picker and the code that presents `SysCfgSheet` are in files that were not staged.

### `Views/SysCfgSheet.swift` (240 lines)
- Sheet with an "Experimental" banner, running view with log tail, error view (offers "Build SSH ramdisk" for legacy or "Build SSH ramdisk (SSHRD)"), read result with field box and "Save dump…", and a "SysCfg restored & verified" view.
- State: complete. The build buttons are chosen by matching substrings of the error message ("No SSH ramdisk", "no built ramdisk"), which will break silently if those messages are reworded.

### `Views/HealthView.swift` (201 lines)
- Quick check and Boot test cards, `HealthChecklist` (USB link, processor, board, boot ROM, unlock, NAND wait time), and `BootedPodCard` with "Pull diagnostics" always shown and "Read SysCfg" / "Restore SysCfg…" behind the Advanced setting.
- State: complete.

### `Views/RestoreView.swift` (217 lines)
- Restore page: auto-restore toggle, "Restore all", firmware summary with signing badge, connection guide (links to the Nic's Fix shop for the adapter), session history.
- State: complete. No SysCfg content. Uses `DeviceCard`, `Card`, `Banner`, `StepRow`, which are not staged.

## 5. Scripts

### `HomePodRestoreApp/scripts/build-ssh-ramdisk.sh` (81 lines)
- Six steps: `img4tool -e` the donor ramdisk, mount, create a 300 MB HFS+ image seeded from it, `ditto` the overlay in, check for `usr/local/bin/dropbear`, convert to ULFO, `img4tool -c -t rdsk`.
- State: works for a plaintext donor ramdisk only. The keys zip argument is accepted but never used; no decrypt path exists. Header lists `img4` and `ldid` as tools but neither is called. The overlay directory (`scripts/ssh-ramdisk-overlay/`) is not staged. Used only by `SSHRamdiskBuilder.swift` (legacy path).

### `HomePodRestoreApp/scripts/setup-tools.sh` (161 lines)
- Installs Homebrew if missing, the d235j tap, HEAD libimobiledevice-glue / libimobiledevice / libirecovery / ldid-procursus, libusbmuxd for iproxy (non-fatal), removes the tap's idevicerestore, builds idevicerestore at `d2e1c4f` with the `irecv_init` fix into `/usr/local/bin`, builds gaster with the ECID patch into the app support `bin`. `--builder` adds libgeneral, img4tool, tsschecker, libpatchfinder, ra1nsn0w.
- State: complete for restore and build. Does not install `sshpass`. Needs the unstaged `patches/gaster-ecid.patch` (falls back to stock gaster).

## 6. Legacy and reference

### `SSHRD_Script/README.md` (67 lines)
- The upstream verygenericname SSHRD_Script README, unchanged: generic A7 to A11 usage, `sshrd.sh <version>`, `boot`, `ssh`. No HomePod or d235j-branch notes, and no mention of the `ota` argument the app uses.

### `SSHRD_Script/diags_boot.sh` (116 lines)
- Builds and boots an **11.2.5 DIAGS** SSH ramdisk for b238/A8 so the writable `AppleDiagnosticDataAccess` kext can be loaded with `kextutil` and a `syscfg_write` tool run on the pod. Stages: `images` (iBSS/iBEC via `gaster decrypt` + iBoot64Patcher, devicetree, a pre-patched DIAGS kernelcache, ramdisk with `atvssh.tar.gz` and the `/diags` payload) and `boot` (irecovery chain, no trustcache, manual flip prompt).
- State: draft / experimental. Depends on inputs not staged: `11.2.5/AssetData/boot`, `diags_extract/` (IM4M, patched kernelcache, the kext), `kext_tools/`, `tools/syscfg_write`. Refers to a "STAGE 0" that is not in the script, has a truncated comment, and the usage line omits the `ramdisk` subcommand. Boot-args include `nand-enable-reformat=1 -restore` plus AMFI/code-signing disables.
- Not referenced by the app or by any staged doc.

### `restoregui/HomePodRestore/restorer.sh` (309 lines)
- The old menu-driven bash restorer (six options): install Homebrew and dependencies, flash a pre-made IPSW (`gaster pwn`, `gaster reset`, `idevicerestore -d -e`, seven log checkpoints), custom IPSW (a stub that only prints a message), update IPSW path (rewrites itself with `sed`), download `https://nicsfix.com/ipsw/17.6.ipsw`, exit.
- State: legacy, superseded by the Swift app. Uses the tap's idevicerestore (which the new installer removes as the wrong version), points at 17.6 rather than 18.3, single pod only. No SysCfg or NAND features.

### `restoregui/HomePodRestore/README.md` (15 lines)
- Three-step download / chmod / run note for `restorer.sh`. Complete, minimal.

## 7. Answers to the four focus questions

### SysCfg: exists vs planned

| Capability | Status |
|---|---|
| Read live SysCfg over SSH (ioreg property) | Implemented; docs record it proven on a pod |
| Parse and show serial, MACs, model, region | Implemented; MLB never shows, `00` bytes in a MAC mis-parse |
| Save dump to file | Implemented |
| Validate a dump before restore | Implemented |
| Write, read back, byte-compare flow | Implemented in code, tested only with the fake transport |
| Actual on-pod write mechanism (the sink) | Missing; refused by a gate |
| Write-facility probe (read-only) | Implemented, bundled into diagnostics |
| ASPStorage write unlock (`ASPSetWritable`) | Proven on hardware per the 17.5 doc; lives in unstaged `tools/syscfgset`, not in the app |
| setProperties kernel patch | Shelved as unsafe |
| Effaceable user client GetLocker / SetLocker | Planned; RE done on 18.3, no code, no hardware test; locker type_id and class unknown |
| 11.2.5 DIAGS kernel + writable kext | Script exists; outcome undocumented |
| Carving a dead chip's dump (Reviv) | Mentioned only; no code |

### NAND-related code and docs
- Docs: `homepod-nand-map.md` (device map), the two write-RE docs.
- Code: panic-log read from `/dev/rdisk3` in `DiagnosticsController`; NAND health items in `HealthChecklist` driven by restore-log parsing; the gated SysCfg write. No raw NAND read/write or partition code beyond that. disk1 slices and disk4 are still unexplored.

### SSH ramdisk pipeline

| Path | Build | Boot | Status |
|---|---|---|---|
| Pre-booted | Tech uses SSHRD by hand | App connects, starts iproxy | Works today per the docs |
| SSHRD (default when a checkout exists) | `SSHRDRamdiskBuilder` runs `sshrd.sh ota 17.5` | `SSHRDBooter` native irecovery chain | Implemented; needs a d235j homepod-branch checkout at `~/SSHRD_Script`; one pod at a time |
| Legacy | `SSHRamdiskBuilder` + `build-ssh-ramdisk.sh` | `GasterRamdiskBooter` (ra1nsn0w) | Labelled known-unreliable; plaintext ramdisk only; boot-args issue |
| DIAGS 11.2.5 | `diags_boot.sh images` | `diags_boot.sh boot` | Standalone experiment, outside the app |

### Tools the app depends on
- Restore: `gaster` (ideally the `GASTER_ECID` build), `idevicerestore` at `d2e1c4f`; `irecovery` optional.
- Build-your-own IPSW: `ra1nsn0w`, `img4tool`, `tsschecker`, `binrider` (libpatchfinder), `ldid`, plus `makeipsw.sh` and `firmware_keys.zip` downloaded at run time.
- SysCfg / diagnostics: `/usr/bin/ssh`, `sshpass`, `iproxy`, `irecovery`, `gaster`; for SSHRD mode the checkout's `sshrd.sh` and `Darwin/` tools (img4, iBoot64Patcher, gtar and others); for legacy mode `ra1nsn0w`, `tsschecker`, `img4tool`, `hdiutil`, `ditto`, `osascript`, and a bundled `apticket-0x7000.shsh`.
- System: `/usr/bin/killall`, `/bin/sh`, Homebrew (unless tools are bundled), `dylibbundler` for bundling.
- Gaps: `sshpass` is installed by nothing; `iproxy` and `sshpass` are not tracked on the Setup screen.

## 8. Referenced but not staged
- App sources: `ProcessRunner`, `ToolEnvironment`, `AppPaths`, `Links`, `IPSWBuilder`, `ZipArchive`/`ZipDirectory`, `Downloader`, `FirmwareCatalog`, `FirmwareLibrary`, `RestoreProgress`, `ErrorCatalog`, `USBMonitor`, `ToolInstaller`, `SupportReport`, shared views (`DeviceCard`, `JobCard`, `Card`, `Banner`), tests and fixtures.
- App scripts and resources: `build-app.sh`, `bundle-tools.sh`, `patches/gaster-ecid.patch`, `ssh-ramdisk-overlay/`, `Distribution/manifest.json`, `apticket-0x7000.shsh`.
- On-pod tools: `tools/syscfgset`, `tools/kc-syscfg-patch/patch.py`, `kc-syscfg-patch-183.py`, `tools/syscfg_write`.
- Data: `SSHRD_Script/syscfg.bin` (the known-good 131072-byte blob), `diags_extract/`, `11.2.5/`, `kext_tools/`.

## 9. Folders present but not staged (not read)
- `SSHRD_Script/`: boot log images, Darwin/Linux scripts, diagnostics tools.
- `discord chat group homepod restore/`: 18 pages of chat JSON plus media; the runbook cites this export as the source of the confirmed boot commands.
- `homepodstuff/`: 18.3.ipsw, 26.0.1.ipsw, BuildManifest.plist, firmware/, idevicerestore, makeipsw.sh.
- `keys/`: fwkeydb_tools.
- `.claude-scratch/`: working scratch.
