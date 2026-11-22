# HomePod Hospital — Knowledge Transfer

> **Name.** The app and project are called **HomePod Hospital** (renamed from HomePod Restore /
> HomePodRestore in November 2026). The folder `~/homepod/HomePodRestoreApp/`, the Swift package,
> its targets (`HomePodRestore`, `HomePodRestoreCore`) and the bundle identifier
> `com.nicsfix.homepodrestore` keep the old name on purpose; the README's "Names" section says why.
> The app can also boot **Nicotine**, the Linux system for the HomePod: see `nicotine-boot.md`.

Last updated: 2026-11-16

This is the hand-off document for the HomePod Hospital project. It is written
so that a new AI session (or a person) with no prior context can continue
the work. Read this first, then the topic docs it points to.

**How to read the confidence marks**

- **[verified]** — confirmed on real hardware, or checked against a saved
  log or file on disk while writing this document.
- **[session]** — a finding from the research session that this document
  records as reported. It was not re-checked while writing. Re-verify before
  building on it.
- **[plan]** — intended or proposed work, not yet done.

**Companion docs in this folder**

| File | Covers |
|------|--------|
| `diags-boot.md` | DIAGS boot, SysCfg commands, NAND replacement, color reconfiguration, SEP diagnosis, NAND health |
| `ssh-ramdisk-runbook.md` | SSH ramdisk boot procedure |
| `homepod-nand-map.md` | NAND partition layout |
| `syscfg-write-re.md` | Reverse engineering of the SysCfg write path |
| `syscfg-reference-capture.txt` | `syscfg list` capture from the working pod |
| `writesink-architecture.md` | App write-path architecture |
| `nicotine-boot.md` | Booting Nicotine (Linux) from the app: sequence, image folder, settings, what is unverified |

---

## 1. HomePod 1st Gen Hardware Reference

| Item | Value |
|------|-------|
| Device | `AudioAccessory1,1`, model A1639 |
| SoC | Apple A8 / T7000, `CPID:7000` |
| Board | `b238aAP`, `BDID:38` |
| Board revisions seen | `0x5` (working pod), `0xa` (dead-SEP pod) [session] |
| Bootrom | Vulnerable to checkm8 |
| RAM | 1 GB |
| NAND | 16 GB, Toshiba THGBX4G7D2LLDYC |
| WiFi/BT | USI 339S00450 module (BCM43572 or similar), on PCIe |
| Tweeter amps | 7x SSM3515B (I2C control, TDM I2S audio) |
| Woofer path | CS4350 DAC (I2S) into a PowIRaudio class-D amp |
| Amp controller | STM32L051 MCU, code name "Nitrogen" |
| Microphones | 6, via 2x Conexant CX20810 |
| Accelerometer | Bosch BMA282, I2C, chip ID `0xfb` |
| UART | 115200 baud, 8N1, no flow control |
| USB | Synopsys DWC2 OTG |

The part list is from the session's teardown and firmware research
[session]. `CPID`, `BDID`, ECIDs and serials below are from saved UART logs
[verified].

---

## 2. Boot Methods

All methods except the normal boot start from DFU with the checkm8 exploit.
checkm8 is tethered: it must be re-run after every power cycle.

### 2.1 Normal audioOS boot
iBoot loads the kernel from NAND and boots audioOS. Requires a working SEP.

### 2.2 DFU + checkm8
`gaster pwn` exploits the bootrom, `gaster reset` resets USB, then
`irecovery` sends images.

### 2.3 Dev DIAGS boot [verified]

```
gaster pwn
gaster reset
irecovery -f iBSS.img4
irecovery -f iBEC.img4
irecovery -f diag.img4
irecovery -c go
```

- Pre-built files: `~/Downloads/diagsstuffnic/` (`iBSS.img4`, `iBEC.img4`,
  `diag.img4`). Not device-specific.
- The iBSS/iBEC are the development iBoot `iBoot-4076.30.43` taken from the
  ProtoPod prototype dump. It skips signature validation.
- UART shows `BUILD_STYLE: DEVELOPMENT`, then the `[ECID] :-)` prompt.
- Does not initialize the SEP.

### 2.4 SSH ramdisk
checkm8 → iBSS → iBEC → restore ramdisk → SSH over USB. See
`ssh-ramdisk-runbook.md`. Does not initialize the SEP.

### 2.5 Linux boot (new) [plan]
checkm8 → iBSS → iBEC → m1n1 → Linux kernel.

- HoolockLinux project: https://github.com/HoolockLinux
- Its `remote_boot` repo already lists `AudioAccessory1,1` [session].
- Still needed: a HomePod device tree, `t7000-b238a.dts`.
- Nothing has been booted on a HomePod yet. See sections 6 and 7.

---

## 3. Factory DIAGS Shell

- **Access:** UART at 115200 8N1 after booting `diag.img4`.
- **Prompt:** `:-)` (printed as `[ECID] :-)`).
- **Key commands:** `syscfg`, `cbreadall`, `temperature`, `sensor`, `wifi`,
  `bluetooth`, the `nand*` reads (`nandcsid`, `nandppnfwver`, `nanduid`),
  `audio`, `playaudio`, `dfufile`, `usbfs`. `help <command>` prints usage.
  Most commands need arguments and print only a usage error when typed bare.
- **DANGEROUS — do not run `NANDInfoTool`.** It panics DIAGS with a null
  pointer dereference in `TestNand.macho` and the pod drops back to DFU
  [verified].

### SysCfg

- A 128 KB NAND partition, version `0x00020002`, 22 entries on the reference
  unit [session].
- Subcommands: `init`, `add`, `delete`, `print`, `list`, `dump`, `rawdump`,
  `stats`, `type`.
- **Always save `syscfg list` before writing anything.** It is the only
  record of a unit's identity and calibration.
- Full key table and usage: `diags-boot.md`.

---

## 4. Color Reconfiguration [verified on real hardware]

Three SysCfg keys carry the color. All three must be changed and must agree,
or the iOS setup prompt keeps showing the old color.

| Key | Meaning | Space Gray | White |
|-----|---------|------------|-------|
| `Mod#` | Model number | `MQHW2` | `MQHV2` |
| `CLCG` | Cover Glass Color | last 32-bit word `0x00000001` | last 32-bit word `0x00000002` |
| `CLHS` | Housing Color | last 32-bit word `0x00000001` | last 32-bit word `0x00000002` |

- `CLCG`/`CLHS` are four 32-bit words:
  `0x00000001 0x00000000 0x00000000 0x0000000N`.
- The BLE proximity pairing advertisement (service UUID `0xFE25`) is built
  locally from `CLCG`/`CLHS`, which is why `Mod#` alone is not enough
  [session].
- Result: the iOS setup prompt showed the new color after the change.
- Exact command sequence, and the app feature that automates it
  (DIAGS Shell → Reconfigure Model…): `diags-boot.md`.

---

## 5. SEP Diagnosis and Dead-SEP Boards

- The SEP is a coprocessor inside the A8 die, not a separate chip.
- The SEP ROM is mask ROM, fixed at fabrication. It cannot be reflashed.
- **Symptoms** [verified against `uartlogduringrestoreattempt.0`]:
  - restore stops at `load_sep_os` (`RESTORED:[0x0609]`);
  - UART shows `"SEP ROM boot panic. 0x..." @SEPROMPanicBuffer.cpp:71`;
  - `IBFL` increments between attempts.
- The AP, NAND, USB, WiFi and audio hardware keep working.
- DIAGS and ramdisks boot, because they never initialize the SEP.
- **The board is unrepairable for this fault.** Only an SoC replacement
  would fix it.
- **Red herrings:** `kIOReturnUnformattedMedia` (NAND not yet formatted) and
  `AppleExternalAmpController ... hw overrun` (seen on working pods too).
- Linux never initializes the SEP, so a dead-SEP board can in principle
  still run Linux. That is the motivation for section 6.

Step-by-step diagnosis with log excerpts: `diags-boot.md`, "SEP Diagnosis".

---

## 6. Linux on Dead-SEP HomePods (new project) [plan]

**Goal:** give dead-SEP boards a second life, e.g. as an AirPlay speaker
running `shairport-sync`.

- HoolockLinux boots Linux on A7–A11 devices through checkm8 [session].
- Boot chain: gaster checkm8 → iBSS → iBEC → m1n1 → Linux kernel.
- The SEP is irrelevant: Linux does not touch it.

**What the HomePod still needs**

| Area | Status |
|------|--------|
| Device tree `t7000-b238a.dts` | Not written |
| Tweeter amps (SSM3515) | Driver is in mainline Linux |
| SoC audio (MCA) | Driver exists for newer SoCs; needs adapting to A8 |
| Woofer path, Nitrogen MCU | No driver; protocol not documented |
| WiFi | Blocked — no A8 PCIe root complex driver |
| Network workaround | USB ethernet gadget to a companion board |

**Constraints**

- Always tethered: checkm8 must be re-run on every power cycle, so a
  companion board (or a host) has to stay attached to re-exploit and boot.
- No speaker protection under Linux — read the warning in section 7 before
  playing any audio.

Other agents in the originating session were working on the device tree,
the Linux build, the audio hardware and SEP bypass. Their results are not in
this document; check for their output before repeating that work.

---

## 7. Audio Hardware Chain (for driver development)

```
SoC MCA -> audio mux -> codec0 / codec1 -> amp controller (Nitrogen STM32) -> speakers
                                  tweeters: 7x SSM3515B (I2C + TDM I2S)
                                  woofer:   CS4350 DAC (I2S) -> PowIRaudio class-D amp
```

- DIAGS audio blocks seen in `playaudio --listcaps`: `socmca` (the only one
  marked playable, 8–96 kHz), `ampcontroller`, `codec0`, `codec1`
  (48 kHz / 16-bit) [verified].
- DIAGS audio test port: `ap-mca3` [session]. `diags-boot.md` still records
  tone playback as "not yet confirmed to play" — update it once a
  `playaudio -b socmca -p ap-mca3 ...` line has been run and heard.
- **SmartIOFirmwareT7000.bin** — coprocessor firmware needed for audio
  [session]:
  - 493,516 bytes (about 482 KiB);
  - extracted from the ProtoPod kernelcache to `/tmp/SmartIOFirmwareT7000.bin`;
  - not present on retail units;
  - can be pushed to a pod's NAND with `dfufile --write`.
  - `/tmp` is cleared on reboot. If the file is gone, re-extract it from
    `~/Downloads/diagsstuffnic/protopod_extract/System__Library__Caches__com.apple.kernelcaches__kernelcache`
    and keep a copy somewhere permanent.
- ProtoPod audio plug-in files (`PuffinPlugin`, `PuffinDSPDatabase.plist`,
  `PuffinSpeakerCalibration.plist`, `PuffinMicCalibration.plist`) are in
  `protopod_extract/` and are the best available reference for the DSP
  configuration [verified present].

### WARNING — no speaker protection under Linux

audioOS does the crossover, EQ and excursion limiting in software DSP. None
of that exists under Linux. **Driving the drivers without it can physically
damage them** — full-range signal into the tweeters or unlimited excursion on
the woofer. Before any playback:

- put a crossover and limiter in the path (CamillaDSP or ALSA plugins);
- start at very low gain;
- never send low frequencies to the tweeter channels.

---

## 8. NAND Replacement and Identity

- `syscfg add` works for identity keys: serial (`SrNm`), `MLB#`, `Mod#`,
  `Regn`, MAC addresses (`WMac`, `BMac`, `EMac`).
- The calibration blobs are too large for the DIAGS command line: `WCAL` is
  2204 bytes, `BCAL` is 3444 bytes [session].
- Those need the iOS-side effaceable / SetLocker path instead. See
  `syscfg-write-re.md` and `~/homepod/SYSCFG_WRITE_FINDINGS.md`.
- Factory control bits (`cbreadall`) record which factory test stations the
  unit passed.
- Workflow: `diags-boot.md`, "NAND Replacement Workflow".
- A raw SysCfg baseline of the working pod is saved at
  `~/homepod/syscfg-baseline-SERIAL000001.bin`.

---

## 9. Tools and Repos

| Tool | Purpose |
|------|---------|
| gaster | checkm8 exploit tool for A8 |
| irecovery | USB communication with DFU / recovery mode devices |
| ra1nsn0w (tihmstar) | Sends boot components to devices in recovery |
| idevicerestore (d235j fork) | HomePod USB restore |
| HomePodRestoreApp | The app this repo builds — `~/homepod/HomePodRestoreApp/`, Swift, SPM |
| img4, img4tool, iBoot64Patcher | Image packing and iBoot patching; binaries in `~/Downloads/diagsstuffnic/` |
| HoolockLinux | Linux on A7–A11 — https://github.com/HoolockLinux |
| m1n1 | Bootloader stage used by the Linux boot chain |
| pongoOS | checkra1n's pre-boot environment for checkm8 devices |
| shairport-sync | AirPlay receiver for Linux |
| CamillaDSP | Candidate for crossover / limiting under Linux |

---

## 10. Known Working Pod (comparison unit)

| Item | Value |
|------|-------|
| ECID | `0000000000000001` |
| Serial | `SERIAL000001` |
| Board rev | `0x5` |
| Model | `MQHW2` (Space Gray), region `LL/A` |
| SEP | Working |

- Boots with the dev `iBoot-4076.30.43` from ProtoPod.
- Boots DIAGS and SSH ramdisks, and restores normally.
- Its SysCfg is the reference capture (`syscfg-reference-capture.txt`).
- Use it to check whether a log line is a real fault or normal noise.

---

## 11. Dead-SEP Pod (diagnosed this session)

| Item | Value |
|------|-------|
| ECID | `0000000000000002` [verified] |
| Serial | `SERIAL000002` [verified] |
| Board rev | `0xa` [session] |
| iBoot | `iBoot-11881.80.57` during the restore attempt; `iBoot-13822.80.422.0.2` on the following boot [verified] |
| Fault | `SEP ROM boot panic` at `load_sep_os` [verified] |
| IBFL | `0x1C` → `0x1D` across the attempt [verified] |
| NAND | Also degraded: `NAND_UNC` on blocks `[8,14]` and `[9,15]`, SysCfg missing (`[255,255]`) [session] |

- Logs: `~/homepod/HomePodRestoreApp/uartlogduringrestoreattempt.0` and
  `uartlogbootattempt.0`. A diag capture folder also exists at
  `~/homepod-diag-unknown-2026-11-15T06-02-33Z/` (`ioreg.txt`, `notes.txt`,
  `syscfg-write-probe.txt`); confirm which pod it belongs to before citing it.
- The `NAND_UNC` and `[255,255]` lines are not in the two saved UART logs.
  Re-capture them before relying on the block numbers.
- Cannot be returned to audioOS. It is the candidate for the Linux revival
  project.

---

## 12. File Locations

| Path | Contents |
|------|----------|
| `~/homepod/HomePodRestoreApp/` | App source (`Package.swift`, `Sources/`, `Tests/`, `docs/`, `scripts/`, `tools/`, `reports/`) |
| `~/homepod/HomePodRestoreApp/docs/` | This document and the topic docs |
| `~/Downloads/diagsstuffnic/iBSS.img4`, `iBEC.img4`, `diag.img4` | Pre-built DIAGS boot files |
| `~/Downloads/diagsstuffnic/protopod_extract/` | Files pulled from the ProtoPod image: kernelcache, `diag-B238*.im4p`, factory test images (`sepboot`, `rbm`, `hammer`, `console`), Diags scripts, Puffin audio plug-in |
| `~/ProtoPod/HomePod_rdisk0.img` | ProtoPod system image, 16 GB (also `rdisk1`, `rdisk2`, and `.gz` originals) |
| `/tmp/SmartIOFirmwareT7000.bin` | SmartIO firmware, 493,516 bytes — **volatile location** |
| `~/homepod/SYSCFG_WRITE_FINDINGS.md` | SysCfg write research notes |
| `~/homepod/syscfg-baseline-SERIAL000001.bin` | SysCfg baseline of the working pod |
| `~/homepod/SSHRD_Script/`, `~/homepod/keys/` | SSH ramdisk tooling and keys |

---

## 13. Open Questions and Next Steps

1. Write `t7000-b238a.dts` and get a first Linux boot with UART output on
   the dead-SEP pod.
2. Confirm the `remote_boot` `AudioAccessory1,1` entry actually boots this
   board.
3. Confirm DIAGS tone playback with the `ap-mca3` port, then update
   `diags-boot.md`.
4. Work out how SmartIO firmware and the Nitrogen MCU are brought up, and
   whether Linux can do it without the audioOS stack.
5. Design the DSP protection chain before any Linux audio playback.
6. Move `SmartIOFirmwareT7000.bin` out of `/tmp`.
7. Re-capture the dead-SEP pod's NAND errors to a saved log.
8. Calibration blob write path (`WCAL`, `BCAL`) for NAND replacement is
   still unsolved from DIAGS.

## 14. Safety Rules for Whoever Continues

- Never run `NANDInfoTool`.
- Save `syscfg list` before any SysCfg write.
- Do not play audio under Linux without a crossover and limiter.
- Do not spend more restore attempts on a pod that shows the SEP signature;
  each one only increments `IBFL`.
