# HomePod SSH-Ramdisk Diagnostic Suite — Design Document

**Target:** 1st-gen HomePod (AudioAccessory1,1 / A1639, Apple A8 / T7000), booted into the
checkm8 SSH ramdisk already built by `HomePodRestoreApp`.
**Author:** diagnostics-design agent · **Date:** 2026-11-14

---

## 0. Grounding — what we already have to build on

The plan deliberately reuses the existing, proven plumbing rather than inventing a new channel:

- **Boot + shell:** `SSHRDBooter` / `GasterRamdiskBooter` boot the pod; `PreBootedBooter` attaches to a
  tech-booted pod. Both yield a `BootedPod` whose `.shell` conforms to **`RamdiskShell`** with exactly
  two primitives — `run(cmd) -> String` (text) and `dumpBinary(cmd) -> Data` (base64-framed binary).
- **Transport proven today:** `SSHRamdiskTransport` reads SysCfg by running `ioreg` over SSH and
  carving an IORegistry property. **This is the template for every tool below** — most of them are just
  new `ioreg`/`dd`/shell one-liners whose text output we parse Mac-side.
- **Orchestration template:** `DiagnosticsController.pull(...)` already boots once, then runs a *sequence*
  of read-only probes (panic-log `dd`, `ioreg -l`, write-probe) into a `DiagnosticsBundle`. The new suite
  is modelled as an expansion of exactly this controller.
- **Ramdisk contents today:** bash, coreutils (`dd`, `cat`, `ls`, `grep`, `find`, `hexdump`), `sqlite3`,
  dropbear, **`ioreg`**, **`img4tool`**. Anything a tool needs beyond this list is called out explicitly
  in §3.

**Key architectural fact that shapes everything:** the A8 HomePod boots from `md0` (the RAM disk), and
ASP (Apple Storage Processor) therefore forces storage **read-only** (`ASPStorage - Ramdisk rooted.
Returning readonly`, per the repo's own `syscfg-write-re.md`). So the whole suite is **read-only by
construction** — which is exactly what we want for non-destructive intake diagnostics. No tool here
writes to NAND.

### Hardware we are diagnosing (from the iFixit/iClarified teardown)
- **7 tweeters** in a beamforming array + **1** upward-firing 4" high-excursion **woofer**.
- **6 far-field microphones** in a beamforming array, **plus 1 low-frequency mic** for woofer
  calibration (7 mic elements total).
- **Apple A8** SoC, **16 GB** NAND flash, 802.11ac Wi-Fi (MIMO), Bluetooth 5.0.
- **Accelerometer** for tap/touch handling, driven by the **AOP** (Always-On Processor) coprocessor.

The sensor-bearing parts (mics, accelerometer) hang off the **AOP**, which the restore ramdisk does **not**
bring up — this is the single biggest feasibility constraint and is flagged honestly per tool.

---

## 1. Executive summary — proposed tools, ranked by shop value

| # | Tool | What it proves for a repair | Feasibility |
|---|------|------------------------------|-------------|
| **P1** | **NAND Health / SMART** (`hpdiag-nand`) | The #1 HomePod failure. Wear, retired/bad blocks, read-error counters, ASP status, "is this chip dying." | **Probable** (ioreg ASPDiagnostic/ASPStorage) |
| **P2** | **NAND partition & boot-chain integrity** (`hpdiag-partmap`) | All expected `/dev/disk*` present, LLB/iBoot/panic regions valid, img4 magic intact. Confirms a NAND swap took. | **Definite** (dd + img4tool, already partly done) |
| **P3** | **Factory-data completeness** (`hpdiag-factory`) | Beyond serial/MACs: all SysCfg calibration tags + effaceable lockers present. Catches an incomplete donor NAND. | **Definite** (ioreg, extends current SysCfg read) |
| **P4** | **Thermal snapshot** (`hpdiag-thermal`) | A8 die / PMU temps. Overheat = PSU or thermal-pad / reassembly fault. | **Probable** (ioreg thermal nodes) |
| **P5** | **Power / PMU rails** (`hpdiag-power`) | PMU voltages/boot-flags + Mac-side USB-during-DFU. Catches PSU & power-delivery faults. | **Probable** (ioreg PMU) + **Definite** (USB) |
| **P6** | **Radio presence** (`hpdiag-radio`) | Wi-Fi + BT chips enumerate, firmware loads, MACs match SysCfg. "Radios are alive." | **Probable** (ioreg) — not an RF/throughput test |
| **P7** | **Audio output test** (`hpdiag-audio`) | The holy grail: "does sound come out." Tweeter/woofer continuity. | **Needs investigation** (hard; see §2.P7) |
| **P8** | **Microphone test** (`hpdiag-mic`) | Capture from the 6+1 mic array. | **Unlikely from restore ramdisk** (AOP) |
| **P9** | **Accelerometer test** (`hpdiag-accel`) | Tap sensor live. | **Unlikely from restore ramdisk** (AOP) |
| **P0** | **One-shot "Intake Report"** | Runs P1–P6 in one boot, emits a single JSON + a printable PASS/WARN/FAIL card. | **Definite** (orchestration) |

**Bottom line for the shop:** P1–P3 + P0 deliver the most value fastest and are low-risk — they turn
the ramdisk into a real intake-bench triage tool. P4–P6 are strong "probable" adds that mostly need a
one-time on-bench enumeration pass (an `ioreg -l` dump from a known-good pod) to pin exact property
names. P7–P9 are where honesty matters: real audio/mic/accel testing from the stock restore ramdisk is
hard-to-impossible without bringing up coprocessors the ramdisk doesn't load — see §2 for what *is*
achievable (continuity/enumeration) vs. what needs a custom diags kernelcache.

---

## 2. Detailed tool specs

Each tool follows the same contract: **one shell command (or short script) producing one JSON object on
stdout**, framed so the existing transport can recover it. Design rule: emit JSON with a sentinel so the
Mac side can carve it out of banner/stderr noise exactly like the SysCfg markers:

```
echo '===HPDIAG_JSON_BEGIN==='; <tool> ; echo '===HPDIAG_JSON_END==='
```

On-device the tools are tiny `sh`/`awk` wrappers around `ioreg`, `dd`, `img4tool`. Where a tool shells
`ioreg`, remember PATH must be set (the current transport already does
`PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin`).

---

### P1 — NAND Health / SMART (`hpdiag-nand`)  ·  Probable

**What it tests/reports.** SMART-equivalent health of the 16 GB raw NAND as managed by ASP: program/erase
cycle estimates, retired/bad-block count, spare-block availability, uncorrectable/read-error counters,
ASP controller status, and the "is storage write-locked / ramdisk-rooted" flag. On A8 the NAND is **raw
flash behind ASP**, *not* an NVMe/ANS2 drive (that's A9+), so the data source is the **ASP diagnostic
IORegistry nodes**, not NVMe telemetry.

**How it works on-device.** The repo's own RE already proved these nodes exist on this ramdisk:
`ASPStorage`, `ASPDiagnostic`, `AppleNANDConfigAccess`, under `ASPStorage`/`ASPDiagnostic`. Query them and
dump every numeric property:

```sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin
for cls in ASPDiagnostic ASPStorage AppleNANDConfigAccess AppleEffaceableStorage; do
  echo "## $cls"
  ioreg -r -c "$cls" -l 2>/dev/null
done
```

Mac-side we parse out keys of interest. Property names to confirm on a known-good pod (names vary by ASP
version; enumerate once from a full `ioreg -l`): `Statistics`, `Lifespan`, `blockCount`,
`badBlockCount` / `retiredBlockCount`, `spareBlocks`, `wearLevel` / `maxEraseCount` / `avgEraseCount`,
`readErrors` / `uncorrectableErrors`, `nand-readonly`, controller temperature if present.

**Data format.**
```json
{"tool":"nand","ok":true,"source":"ASPDiagnostic",
 "capacityBytes":16000000000,"blocksTotal":4096,
 "badBlocks":12,"spareBlocksFree":40,"spareBlocksTotal":64,
 "eraseCountAvg":180,"eraseCountMax":420,"eraseCountRated":3000,
 "uncorrectableErrors":0,"readRetrySeen":3,
 "writeLocked":true,"ramdiskRooted":true,
 "wearPercentEstimate":6,"verdict":"pass","raw":{...}}
```

**App integration.** New `NANDHealth` Codable in Core; a row-group in `HealthChecklist` ("Storage (NAND)"
already exists as a placeholder judged during restore — upgrade it to show wear %, bad/spare blocks, error
counts). Verdict mapping: `pass` (<70% wear, 0 uncorrectable, spare>20%), `warn` (70–90% / shrinking
spare / read-retries), `fail` (>90% wear / uncorrectable>0 / spare exhausted). A small "wear" bar.

**Feasibility: Probable.** The nodes are *confirmed present*; what's unconfirmed is which numeric health
keys ASP populates in the restore-ramdisk personality (the ReadOnly diag node may expose a subset). The
one-time enumeration resolves this with zero risk. Even the minimum (bad-block + controller status +
write-lock state) is already more than the current "judged during restore" heuristic.

---

### P2 — NAND partition & boot-chain integrity (`hpdiag-partmap`)  ·  Definite

**What it tests/reports.** That every expected block device is present and readable, and that the firmware
regions carry valid Apple container magic. This is the direct "did the NAND swap take / is the flash
wired up" check. From `homepod-nand-map.md` the known layout is: `disk0/0s1` APFS main (encrypted),
`disk1 s1–s5` (TBD), `disk2` ~4 MB firmware/LLB+iBoot, `disk3` ~1 MB panic log, `disk4` special.

**How it works on-device.** Enumerate devices, probe sizes with the *large-block* reads this NAND
requires (512-byte reads return nothing — use `bs=1m`), and sniff magic:

```sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin
ls -la /dev/disk* /dev/rdisk* 2>/dev/null
for d in /dev/rdisk0 /dev/rdisk1 /dev/rdisk2 /dev/rdisk3; do
  sz=$(dd if=$d bs=1m count=1 2>/dev/null | wc -c)      # readable?
  magic=$(dd if=$d bs=1m count=1 2>/dev/null | hexdump -C | head -2)
  echo "$d readable=$sz"; echo "$magic"
done
# validate the firmware region carries a real img4/LLB
dd if=/dev/rdisk2 bs=1m count=4 of=/tmp/fw.bin 2>/dev/null
img4tool -i /tmp/fw.bin 2>/dev/null | head -20     # IM4P/IMG4 parse
strings -a /tmp/fw.bin | grep -E 'Util_Find_SysCfg|iBoot|LLB' | head
```

**Data format.**
```json
{"tool":"partmap","ok":true,
 "devices":[
   {"dev":"/dev/rdisk0","readable":true,"bytes":"GB","type":"apfs-encrypted"},
   {"dev":"/dev/rdisk2","readable":true,"bytes":4194304,"type":"firmware","img4":true,
    "markers":["Util_Find_SysCfg","iBoot"]},
   {"dev":"/dev/rdisk3","readable":true,"bytes":1048576,"type":"panic-log","empty":true}],
 "expectedPresent":true,"firmwareValid":true,"verdict":"pass"}
```

**App integration.** `PartitionMap` Codable; a "Storage layout" disclosure group in Health showing each
device with a ✓/⚠️/✗, size, and detected type. On a fresh NAND swap this is the technician's confirmation
screen. Reuses `DiagnosticsController`'s existing `dumpBinary` path for the region sniff.

**Feasibility: Definite.** All primitives (`ls`, `dd bs=1m`, `hexdump`, `img4tool`, `strings`) are on the
ramdisk or already used by `DiagnosticsController`. The panic-log `dd` is *literally the current
diagnostics pull*. (Add `strings` to the overlay if absent — trivial, see §3.)

---

### P3 — Factory-data completeness (`hpdiag-factory`)  ·  Definite

**What it tests/reports.** Goes beyond serial/Wi-Fi/BT/Eth MAC. Verifies the full SysCfg tag set and the
presence of effaceable lockers that hold factory calibration/identity. A donor NAND that boots but is
missing calibration tags or a locker will fail here before it ever ships.

**How it works on-device.** Two sources, both read-only and both already understood by the codebase:
1. **SysCfg blob** — reuse the proven read (`ioreg -r -c AppleDiagnosticDataAccessReadOnly -l` →
   `AppleDiagnosticDataSysCfg`, 131072 bytes, sig `gfCS`). Parse *all* FourCC tags (the `SysCfg.swift`
   reversed-key parser already does this) and report which expected tags are present/absent.
2. **Effaceable lockers** — the RE (`SYSCFG_WRITE_FINDINGS.md`) mapped the
   `AppleEffaceableStorageUserClient` dispatch, incl. **`GetLocker` (sel 5, read, no debugger gate)** and
   `lockerSpace` (sel 8). A tiny read-only locker-probe tool can enumerate which locker tags exist/are
   populated (nonce, etc.) without any write. (Enumeration of presence/size is safe; `GetLocker` content
   may be gated — report the gate, don't fight it.)

Expected SysCfg tag checklist (from SysCfg.swift / Reviv key set): serial, MLB/Mria, Wi-Fi MAC, BT MAC,
Eth MAC, model (MQHW2-style), region (LL/A), RModel (A1639), plus any audio-calibration tags.

**Data format.**
```json
{"tool":"factory","ok":true,"sysCfgSig":"gfCS","sysCfgBytes":131072,
 "tagsPresent":["Mod#","Regn","WMac","BMac","EMac","Seri","MLB#"],
 "tagsMissing":[],
 "lockers":[{"tag":"nonc","present":true,"bytes":20}],
 "verdict":"pass"}
```

**App integration.** Folds into the existing SysCfg sheet (`SysCfgSheet.swift`) as a "Completeness"
section: a checklist of expected tags with ✓/✗, a red banner if anything required is missing. This is a
natural extension of what the SysCfg read already shows.

**Feasibility: Definite** for the SysCfg half (ships today). **Probable** for the locker-presence half —
the dispatch table is already reversed; needs a minimal read-only IOKit probe binary (§3) or, simpler,
just report locker *space* via the un-gated `lockerSpace` selector.

---

### P4 — Thermal snapshot (`hpdiag-thermal`)  ·  Probable

**What it tests/reports.** A8 die temperature and any PMU/board thermal sensors readable at ramdisk time.
Use: a pod that runs hot in the shop, or whose thermals read implausibly (sensor fault / missing thermal
pad after reassembly / failing PSU dumping heat).

**How it works on-device.** On A8 there is no desktop `AppleSMC`; temperatures surface through the
IORegistry device tree / PMU. Enumerate and grep:

```sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin
ioreg -l -w0 2>/dev/null | grep -iE 'temp|thermal|"die-temp"|sensor' 
ioreg -r -c IOPMrootDomain -l 2>/dev/null | grep -iE 'thermal|temp'
# device-tree thermal sensor nodes (names like gas-gauge/temp-sensor):
ioreg -r -c AppleARMPMUCharger -l 2>/dev/null
ioreg -r -n thermal-sensor -l 2>/dev/null
```

Exact node names (e.g. `AppleT8010...`, PMGR temp channels, `IOThermalManager`) must be captured from a
known-good `ioreg -l`. Values may be raw ADC counts needing a scale factor — report raw + a best-effort °C
with a clear "uncalibrated" flag rather than a fake-precise number.

**Data format.**
```json
{"tool":"thermal","ok":true,
 "sensors":[{"name":"soc-die","raw":30211,"celsius":31.5,"calibrated":false}],
 "maxCelsius":31.5,"verdict":"pass","note":"ramdisk idle; values uncalibrated"}
```

**App integration.** A "Temperature" row in Health (only shown if ≥1 sensor read). Thresholds
conservative and clearly caveated as idle-ramdisk readings.

**Feasibility: Probable.** Thermal data is generally reachable via IORegistry on checkm8 A-series devices,
but which channels the *restore ramdisk* populates (vs. a full OS with the thermal daemon running) is the
unknown. Mark values uncalibrated unless a scale is confirmed. Needs the one-time enumeration.

---

### P5 — Power / PMU rails (`hpdiag-power`)  ·  Probable (on-device) + Definite (USB side)

**What it tests/reports.** Two complementary views:
- **Mac-side (Definite):** USB enumeration quality during DFU/restore — link speed, and the fact the pod
  draws/enumerates correctly. The app *already* reads `ConnectedDevice.speed` and flags
  not-high-speed in `HealthChecklist`. Extend to log re-enumeration stability (pod dropping off = power
  fault).
- **On-device (Probable):** PMU state via IORegistry — power-source/charger node, boot flags, any rail
  voltage/telemetry the PMU exposes. HomePod is mains-powered (no battery), so this is PSU/PMU health, not
  a battery gauge.

**How it works on-device.**
```sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin
ioreg -r -c IOPMrootDomain -l 2>/dev/null
ioreg -l -w0 2>/dev/null | grep -iE 'AppleARMPMU|pmu|voltage|rail|power-source|boot-flag'
```

**Data format.**
```json
{"tool":"power","ok":true,
 "usb":{"speed":"high","stable":true},
 "pmu":{"node":"AppleARMPMU","rails":[{"name":"VDD_MAIN","mv":3800}],"bootFlags":"0x..."},
 "verdict":"pass"}
```

**App integration.** The USB half slots straight into the existing "USB link" checklist item. The PMU half
is a disclosure row. If the pod repeatedly drops USB during a probe, surface "Power delivery unstable —
suspect PSU."

**Feasibility:** USB side **Definite** (data already in hand). PMU-rail side **Probable** — depends on
what the A8 PMU driver publishes to IORegistry in the ramdisk; boot-flags/power-source are reliably there,
fine-grained rail voltages may not be. Enumerate once.

---

### P6 — Radio presence (`hpdiag-radio`)  ·  Probable

**What it tests/reports.** That the Wi-Fi (Broadcom 802.11ac) and Bluetooth controllers **enumerate**,
their firmware/driver attached, and their MACs match SysCfg. This is an *existence/identity* check, not an
RF scan or throughput test (the restore ramdisk has no wpa_supplicant/CoreBluetooth stack).

**How it works on-device.**
```sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin
ioreg -l -w0 2>/dev/null | grep -iE 'AppleBCMWLAN|wifi|bluetooth|AppleConvergedIO|BTM|"local-mac-address"|"bluetooth-address"'
```
Pull `local-mac-address` / `bluetooth-address` properties, compare to SysCfg WMac/BMac.

**Data format.**
```json
{"tool":"radio","ok":true,
 "wifi":{"present":true,"driver":"AppleBCMWLANCore","mac":"d0:81:7a:e3:76:94","matchesSysCfg":true},
 "bt":{"present":true,"mac":"d0:81:7a:e3:76:95","matchesSysCfg":true},
 "verdict":"pass"}
```

**App integration.** Two Health rows ("Wi-Fi radio", "Bluetooth radio") with present + MAC-match. A MAC
mismatch vs SysCfg is a strong "wrong/!provisioned part" signal — valuable after a logic-board or NAND
swap.

**Feasibility: Probable.** The controllers normally attach in a restore ramdisk (they're on the main SoC
fabric, not the AOP). The MAC-match check is high-signal and cheap. RF performance testing is explicitly
**out of scope** (would need a booted OS). Enumerate node names once.

---

### P7 — Audio output test (`hpdiag-audio`)  ·  Needs investigation (hard)

**What it tests/reports.** The repair-shop holy grail: play a test tone and confirm the 7-tweeter array
and the woofer physically produce sound. Even a crude "does *anything* come out" is valuable for verifying
a repair.

**Why it's hard — honest assessment.** The stock restore ramdisk has **no CoreAudio / audio HAL / amp DSP
bring-up**. The HomePod's amps and codec are initialized by audioOS userland + the AOP, none of which the
ramdisk loads. There is no `afplay`, no `/dev/audio`. So you cannot simply `cat tone.wav > /dev/dsp`.

**Paths, roughly in increasing effort / decreasing certainty:**
1. **IORegistry audio-endpoint enumeration (Definite, but not a sound test).** Confirm the audio codec /
   amp I²C/I²S nodes *enumerate* (`ioreg | grep -iE 'audio|codec|amp|speaker|TAS|i2s'`). Proves the audio
   hardware is *wired and detected* — catches a dead codec or unseated flex, without making sound. Ship
   this now as "Audio hardware detected: yes/no + continuity."
2. **Amp register / fault-status read (Probable-ish).** The smart-amp chips (TI-class) expose fault
   registers (open/short load, over-temp) over I²C. If a ramdisk I²C path is reachable, reading each amp's
   fault register tells you *per-channel* whether a tweeter/woofer coil is open or shorted — arguably
   *better* than an ear test for triage. Requires locating the I²C controller + amp addresses (RE /
   device-tree) and a small i2c-read tool. **Needs investigation.**
3. **Custom DIAGS kernelcache tone (Hard).** `diags_boot.sh` already exists to boot a **patched DIAGS
   kernelcache** with a writable diag kext. Apple's own Diags has audio self-tests; a DIAGS-mode path
   could drive a tone. This is the "real" tone test but is the heaviest lift (patched kernelcache + diag
   kext reversing) and is **needs-investigation / research-grade**.

**Recommendation.** Ship **P7a (enumeration + continuity)** under the "Audio" label now, labelled honestly
as "hardware detected, not an audible test." Pursue **P7b (amp fault registers)** as the high-value next
step — it gives per-driver open/short detection, which is what a tech actually needs, without solving full
audio bring-up. Treat P7c as a research track tied to the existing DIAGS work.

**Data format (P7a/b).**
```json
{"tool":"audio","ok":true,
 "codecDetected":true,"ampNodes":["audio-amp@0","audio-amp@1"],
 "amps":[{"ch":"tweeter0","fault":"none"},{"ch":"woofer","fault":"open-load"}],
 "audibleTest":false,"verdict":"warn","note":"woofer reports open load; no tone played"}
```

**App integration.** "Audio" card. Clear two-tier UI: "Audio hardware: Detected ✓" always; per-driver
fault list when P7b lands; a disabled-with-explanation "Play test tone" button until P7c is real, so the
UI never over-promises.

---

### P8 — Microphone array test (`hpdiag-mic`)  ·  Unlikely from restore ramdisk

**What it tests/reports.** Capture a few seconds from the 6 far-field mics + 1 calibration mic and report
per-mic level/liveness.

**Why unlikely.** The mic array is captured through the **AOP** (always-on voice processor) with its own
firmware; the restore ramdisk doesn't boot the AOP or the audio capture stack. No `/dev` capture endpoint
exists at ramdisk time. **Best achievable now:** enumerate the mic/AOP nodes in IORegistry to confirm the
mic board/flex is *detected* (`ioreg | grep -iE 'aop|mic|audio-capture|voicetrigger'`) — a presence check,
not a function test. A true capture test realistically needs a DIAGS kernelcache that brings up the AOP
(research-grade, tied to P7c).

**Data format.** `{"tool":"mic","detected":true,"aopNode":"aop","capture":false,"verdict":"info"}`

**App integration.** A single "Microphone board detected" info row. Do **not** present it as a working-mic
test.

**Feasibility: Unlikely** for real capture; **Definite** for presence-only. Flag honestly.

---

### P9 — Accelerometer test (`hpdiag-accel`)  ·  Unlikely from restore ramdisk

**What it tests/reports.** The tap/touch accelerometer live (read axes, tap it, see values move).

**Why unlikely.** Same AOP constraint as P8 — the accelerometer is an AOP-side sensor; the restore ramdisk
doesn't service it, so there's no live sample stream. **Best achievable now:** IORegistry presence check
of the accel/AOP sensor node. Real axis streaming needs AOP bring-up (research-grade).

**Data format.** `{"tool":"accel","detected":true,"liveSampling":false,"verdict":"info"}`

**App integration.** "Tap sensor detected" info row only.

**Feasibility: Unlikely** for live data; **Definite** for presence-only.

---

### P0 — One-shot "Intake Report" (orchestration)  ·  Definite

**What it does.** Boots the ramdisk **once** and runs P1–P6 (+ P7a/P8/P9 presence checks) back-to-back,
assembling one JSON document and a printable PASS/WARN/FAIL summary card keyed to the pod's serial. This is
the daily-driver: tech plugs in an intake unit, clicks "Run full diagnostics," gets a one-page verdict in
~1 boot.

**How it works.** A new `FullDiagnosticsController` modeled exactly on `DiagnosticsController.pull` — same
boot-once-then-sequence-probes structure, each probe appending its JSON to a bundle. One SSH session, many
`run()` calls.

**Data format.** `{"serial":"CC4VKKTQHQK8","timestamp":"...","tools":[{...P1},{...P2},...],
"overall":"warn"}` — plus save-to-disk (reuse `saveDiagnostics`) so each intake gets an archived report.

**App integration.** A prominent "Run full diagnostics" button on the booted-pod card; results render as
the existing `HealthChecklist` style grid, grouped by subsystem, with an export/print and "copy support
info" (reuse the Discord-report pattern). Archive each run under the serial for repair history.

---

## 3. Ramdisk overlay additions needed

The overlay (`scripts/ssh-ramdisk-overlay/`, injected by `build-ssh-ramdisk.sh`) currently ships dropbear +
launcher + host keys, and the base ramdisk has coreutils/`ioreg`/`img4tool`/`sqlite3`. Additions:

| Add | Why | Effort |
|-----|-----|--------|
| **`hpdiag-*` shell scripts** (`/usr/local/bin/`) | The per-tool one-liners above, versioned with the app so commands aren't hard-coded in Swift string literals. Pure `sh`/`awk`. | Trivial — just drop files in the overlay; `ditto` already preserves exec bits. |
| **`strings`** (arm64) | P2 firmware-region marker sniff. | Small — add if not already present (busybox `strings` is fine). |
| **`awk`/`sed`** confirm present | JSON assembly on-device (keeps Swift parsing simple). | Likely already in base; verify. |
| **`hpdiag-ioprobe`** (tiny arm64 IOKit tool) | Only for P3 locker-presence (`lockerSpace`/`GetLocker`) and any amp I²C read (P7b). Build like the existing `syscfgset` note: tvOS SDK, link CoreFoundation, `dlsym` IOKit at runtime, deploy to a tmpfs. | Medium — reuses the documented `syscfgset` build recipe. |
| **(research) patched DIAGS kernelcache + diag kext** | Only if P7c/P8/P9 real tests are pursued. Already scaffolded in `diags_boot.sh`. | Large / research-grade. |

**Design principle:** keep the tool logic in overlay scripts, not Swift. Swift calls
`shell.run("hpdiag-nand")`; the script owns the command set. This lets Nic iterate tool behavior by
rebuilding the overlay without recompiling the app, and keeps the brittle `ioreg` grep patterns in one
place that's easy to fix after the bench enumeration.

**One-time bench task that de-risks P1/P4/P5/P6:** on a known-good pod, capture a full
`ioreg -l -w0 > ioreg-full.txt` (the diagnostics pull *already* grabs `ioreg -l` — just archive it) and a
`ioreg -lrw0` per candidate class. That single dump pins every unknown property/class name in §2. No new
code needed to collect it — it falls out of the existing "Pull diagnostics" button.

---

## 4. App-side integration plan

Follows the existing Core/UI split (`HomePodRestoreCore` = Foundation-only, testable on Linux; `HomePodRestore` = SwiftUI).

**New Core types (`Sources/HomePodRestoreCore/`):**
- `Diagnostics/DiagTool.swift` — an enum of tools + each result as a `Codable` struct (`NANDHealth`,
  `PartitionMap`, `FactoryData`, `ThermalSnapshot`, `PowerStatus`, `RadioStatus`, `AudioStatus`,
  `SensorPresence`). Each has a `verdict: Verdict { pass, warn, fail, info }` and a `rows: [DiagRow]`
  for UI.
- `Diagnostics/DiagParsers.swift` — pure functions `parseNAND(_ text:) -> NANDHealth`, etc. **These are
  unit-testable on Linux with captured fixture text** (drop real `ioreg`/`dd` output into
  `Tests/.../Fixtures/`), matching the project's existing fixture-driven test style. This is where most of
  the robustness lives.
- `FullDiagnosticsController.swift` — mirrors `DiagnosticsController`: `boot once → run each hpdiag tool →
  assemble bundle`. Reuses `RamdiskShell.run`/`dumpBinary` verbatim. Extends `DiagnosticsBundle` with an
  optional `[DiagToolResult]`.
- Extend `SSHRamdiskTransport` only if a tool needs binary framing beyond `dumpBinary` (it won't — text
  JSON + sentinels suffice).

**New transport commands.** None at the Swift level beyond passing the `hpdiag-*` command strings to the
existing `run()`. Keep a `DiagCommands` struct of the command strings (like
`SSHRamdiskTransport.writeProbeCommand`) so they're centralized and testable, with the sentinel-carving
reusing `extractBetweenMarkers`.

**New / changed UI (`Sources/HomePodRestore/Views/`):**
- Upgrade `HealthView` / `HealthChecklist`: the existing pass/warn/fail row model already fits perfectly —
  add subsystem groups fed by `DiagToolResult.rows`. The "Storage (NAND)" item graduates from
  "judged during restore" to live P1/P2 data.
- `BootedPodCard` gains a **"Run full diagnostics"** button → `AppModel.runFullDiagnostics(...)`
  (new, modeled on `pullDiagnosticsBooted()` in `AppModelSysCfg.swift`).
- A `DiagnosticsReportView` (sheet): grouped results, export JSON, print card, "copy support info"
  (reuse the ECID-redacted Discord report style). Save per-serial via the existing `saveDiagnostics`.
- `AppModelSysCfg.swift` gains `runFullDiagnostics(on:)` and per-tool runners, following the exact
  `@MainActor` + `DiagUIState` + log-append pattern already there.

**Testing.** For each parser, add a fixture (captured on-bench) + a `parse…` unit test. End-to-end:
extend the existing fake-tool harness (`HOMEPOD_FAKE_TOOLS=1`) with a fake `hpdiag-*` that echoes canned
JSON, so the full-diagnostics flow is CI-tested without hardware — consistent with how the project already
fakes gaster/idevicerestore.

---

## 5. Priority ordering (most valuable for a repair shop first)

1. **P2 Partition/boot-chain integrity** — Definite, reuses the existing diagnostics pull, immediate value
   confirming NAND swaps. *Ship first; lowest risk.*
2. **P1 NAND Health/SMART** — the #1 HomePod failure mode; highest diagnostic value. Probable, de-risked by
   the one-time ioreg enumeration.
3. **P3 Factory-data completeness** — Definite SysCfg half ships with P1/P2; catches bad donor NANDs.
4. **P0 Intake Report** — ties 1–3 into the daily workflow; Definite once the first three exist.
5. **P6 Radio presence** + **P5 Power (USB + PMU)** — Probable, cheap, high-signal after board/NAND swaps.
6. **P4 Thermal** — Probable; nice-to-have, needs enumeration + calibration caveats.
7. **P7a Audio enumeration/continuity** + **P8/P9 presence** — Definite as presence checks; ship labelled
   honestly.
8. **P7b Amp fault registers** — the real per-driver open/short test; Needs-investigation but high payoff.
9. **P7c / P8 / P9 real tests via DIAGS kernelcache** — research track, tied to existing `diags_boot.sh`.

---

## 6. Implementation roadmap

**Phase 0 — Enumerate (no new code, 1 bench session).** Boot a known-good pod, run the existing "Pull
diagnostics," archive `ioreg -l`. From it, pin every `?`-marked class/property name in §2 (NAND, thermal,
PMU, radio, audio nodes). This single dump converts most "Probable" ratings to "Definite."

**Phase 1 — Definite tools (P2, P3-syscfg, P0 skeleton).** Add `hpdiag-partmap` + `hpdiag-factory` overlay
scripts, Core parsers + fixtures + tests, `FullDiagnosticsController`, Health UI groups. Ship — the
ramdisk becomes a real intake tool.

**Phase 2 — NAND health + the rest of the read-only suite (P1, P4, P5, P6).** Add the ASP/thermal/PMU/radio
`hpdiag-*` scripts using Phase-0 names, parsers, and UI rows. Full Intake Report (P0) goes live.

**Phase 3 — Factory lockers + audio hardware (P3-lockers, P7a).** Build the small `hpdiag-ioprobe` IOKit
tool (reuse the `syscfgset` tvOS build recipe) for un-gated `lockerSpace`/`GetLocker` presence and audio
codec/amp enumeration.

**Phase 4 — Research track (P7b amp I²C fault registers; P7c/P8/P9 via DIAGS).** Locate I²C controller + amp
addresses; extend `hpdiag-ioprobe` to read amp fault registers (per-driver open/short — the genuinely
useful audio triage). Longer term, fold into the existing patched-DIAGS-kernelcache effort for true tone /
mic / accel tests.

**Cross-cutting guardrails (match the project's honest-assessment ethos):**
- Everything read-only; no NAND writes (ASP ramdisk-rooted read-lock enforces this anyway).
- Every tool emits a `verdict` *and* raw data; never show fake-precise numbers (flag uncalibrated thermal,
  presence-vs-function for audio/mic/accel).
- Keep tool command strings in overlay scripts + a central `DiagCommands`, so post-bench fixes don't need
  an app recompile.
- Parsers are pure + fixture-tested on Linux; full flow fake-tool-tested in CI.

---

### Appendix — feasibility one-liner per tool
- **Definite today:** P2 (partmap), P3-SysCfg (factory tags), P0 (orchestration), presence-only for
  P7a/P8/P9.
- **Probable (needs Phase-0 ioreg enumeration):** P1 (NAND SMART via ASPDiagnostic), P4 (thermal), P5-PMU,
  P6 (radio).
- **Definite + already-in-hand:** P5-USB side.
- **Needs investigation:** P3-lockers (minimal IOKit probe), P7b (amp fault registers over I²C).
- **Research-grade (custom DIAGS kernelcache):** P7c audible tone, P8 mic capture, P9 accel streaming.
