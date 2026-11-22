# DIAGS Boot — Factory Diagnostics Environment

## Overview

The HomePod 1st gen can boot Apple's factory diagnostics environment
("smokeyshell") using development iBoot firmware extracted from a prototype
unit. This gives serial-console access to Apple's factory provisioning
commands, including full SysCfg read/write.

Two boot modes are available:

| Mode | Access | Use case |
|------|--------|----------|
| SSH Ramdisk | SSH over USB | Health checks, SysCfg reading, diagnostics |
| DIAGS Config | Serial (UART) | SysCfg writing, NAND replacement, factory provisioning, color reconfiguration |

## Pre-built Files

Located at `~/Downloads/diagsstuffnic/` (not device-specific — works on any
HomePod 1st gen):

- `iBSS.img4` — Development iBSS (from ProtoPod LLB, decrypted + patched)
- `iBEC.img4` — Development iBEC (from ProtoPod iBoot, decrypted + patched)
- `diag.img4` — Apple DIAGS firmware (from ProtoPod rootfs AppleInternal/Diags/bin)

## Boot Sequence

```
gaster pwn
gaster reset
irecovery -f iBSS.img4
irecovery -f iBEC.img4
irecovery -f diag.img4
irecovery -c go
```

UART will show `BUILD_STYLE: DEVELOPMENT` and the DIAGS shell prompt:
`[ECID] :-)`

## SysCfg Command Reference

| Subcommand | Description |
|------------|-------------|
| `syscfg list` | List all SysCfg entries with values |
| `syscfg print <KEY>` | Print a specific entry |
| `syscfg init` | Initialize blank SysCfg (for new NAND) |
| `syscfg add <KEY> <value>` | Write/add an entry |
| `syscfg delete <KEY>` | Delete an entry |
| `syscfg dump` | Raw hex dump |
| `syscfg stats` | Storage statistics |
| `sn` | Shortcut to read/write serial number |

## Essential SysCfg Keys

| Key | Description | Example |
|-----|-------------|---------|
| `SrNm` | Serial number | SERIAL000001 |
| `MLB#` | MLB serial | MLBSERIAL00000001 |
| `Mod#` | Model number | MQHW2 |
| `Regn` | Region | LL/A |
| `RMd#` | Regulatory model | A1639 |
| `CFG#` | Config number | 0 |
| `WMac` | WiFi MAC address | (hex words) |
| `BMac` | Bluetooth MAC | (hex words) |
| `EMac` | Ethernet MAC | (hex words) |
| `WCAL` | WiFi calibration | (large blob) |
| `BCAL` | Bluetooth calibration | (large blob) |
| `SpEQ` | Speaker EQ | (calibration data) |
| `SpGa` | Speaker gain | (calibration data) |
| `MiGa` | Microphone gain | (calibration data) |
| `WFEQ` | Woofer EQ | (calibration data) |
| `LEDc` | LED calibration | (calibration data) |
| `LSCI` | Light sensor calibration | (calibration data) |
| `CLCG` | Cover Glass Color | `0x00000001 0x00000000 0x00000000 0x00000001` (last word: 1 = Space Gray, 2 = White) |
| `CLHS` | Housing Color | same format and codes as `CLCG` |

`Mod#`, `CLCG` and `CLHS` together carry the unit's color — see
[Color Reconfiguration](#color-reconfiguration-space-gray--white).

## NAND Replacement Workflow

### 1. Read SysCfg from original NAND (before swap)

Boot into DIAGS and run:
```
syscfg list
```
Save the full output — this is the device's identity and calibration.

### 2. Swap the NAND chip

Physical repair step — desolder old NAND, solder replacement.

### 3. Boot DIAGS on new NAND

The new NAND will have no SysCfg. Boot the same way — the DIAGS
environment runs from the diag.img4 loaded over USB, not from NAND.

### 4. Initialize and write SysCfg

```
syscfg init
syscfg add SrNm SERIAL000001
syscfg add MLB# MLBSERIAL00000001
syscfg add Mod# MQHW2
syscfg add Regn LL/A
syscfg add RMd# A1639
syscfg add CFG# 0
syscfg add WMac <hex values from original>
syscfg add BMac <hex values from original>
syscfg add EMac <hex values from original>
```

Calibration blobs (WCAL, BCAL, SpEQ, LEDc, etc.) should also be
written back if captured from the original NAND.

### 5. Restore the HomePod

With SysCfg written, the HomePod can be USB-restored normally.
The device identity (serial, MACs) will match Apple's records,
allowing activation and HomeKit pairing.

## Color Reconfiguration (Space Gray ↔ White)

**Confirmed working on real hardware.** A HomePod can be changed from one
color to the other in software — e.g. after a mesh/housing swap — so that it
identifies as the new color, including in the iOS setup prompt.

The color lives in **three** SysCfg keys, and all three must be written:

| Key | Meaning | Space Gray | White |
|-----|---------|------------|-------|
| `Mod#` | Model number | `MQHW2` | `MQHV2` |
| `CLCG` | Cover Glass Color | `0x00000001 0x00000000 0x00000000 0x00000001` | `0x00000001 0x00000000 0x00000000 0x00000002` |
| `CLHS` | Housing Color | `0x00000001 0x00000000 0x00000000 0x00000001` | `0x00000001 0x00000000 0x00000000 0x00000002` |

`CLCG` and `CLHS` are four 32-bit words in the same format. Only the **last
word** differs — it is the color code: `0x00000001` = Space Gray,
`0x00000002` = White.

Writing `Mod#` alone is not enough: the model number changes, but the iOS
setup prompt keeps showing the original color. With all three keys written
and the firmware restored, the setup prompt shows the new color.

### Procedure

1. Boot into DIAGS (see [Boot Sequence](#boot-sequence)) and save the output
   of `syscfg list` — it is the only record of the original values.
2. Write the three keys. Space Gray → White:

   ```
   syscfg delete Mod#
   syscfg add Mod# MQHV2
   syscfg delete CLCG
   syscfg add CLCG 0x00000001 0x00000000 0x00000000 0x00000002
   syscfg delete CLHS
   syscfg add CLHS 0x00000001 0x00000000 0x00000000 0x00000002
   ```

   White → Space Gray is the same with `MQHW2` and a last word of
   `0x00000001`:

   ```
   syscfg delete Mod#
   syscfg add Mod# MQHW2
   syscfg delete CLCG
   syscfg add CLCG 0x00000001 0x00000000 0x00000000 0x00000001
   syscfg delete CLHS
   syscfg add CLHS 0x00000001 0x00000000 0x00000000 0x00000001
   ```

3. Verify all three by reading them back:

   ```
   syscfg print Mod#
   syscfg print CLCG
   syscfg print CLHS
   ```

   `Mod#` must show the new model, and `CLCG` and `CLHS` must both end in
   the new color code.
4. USB-restore the firmware. After the restore, the iOS setup prompt shows
   the new color.

### In the app

**DIAGS Shell → Reconfigure Model…** does all of this: pick the target color
and it sends the nine lines above in that order (delete + add for `Mod#`,
`CLCG`, `CLHS`, then the three `syscfg print` read-backs) and only reports
success when all three read back with the new values. If a read-back is
wrong it names the key; run it again — the values are fixed per color, so the
sequence is safe to repeat. The sheet also shows the current `CLCG` / `CLHS`
values and flags a unit where `Mod#` and the color keys disagree (for
example one where only `Mod#` was changed earlier).

In code: `HomePodModelVariant` (`colorCode`, `clcgValue`, `clcgArgs`) and
`DiagsSerialSession.modelReconfigureCommands(to:color:)` /
`verifiedModel(from:expected:color:)` / `reconfigureModel(to:color:)`.

### Notes

- `Regn` (region) is a separate key and is not changed. A model string that
  carries a region suffix (`MQHW2LL/A`) keeps it (`MQHV2LL/A`).
- **LED calibration (`LEDc`) is not changed.** It was factory-calibrated for
  the original mesh, so LED colors may look slightly off after a swap.
- `DClr` was not present on the reference unit (see
  `syscfg-reference-capture.txt`) and is not written.
- These are flash writes. Keep the saved `syscfg list` output so the original
  values can be put back.

## Other DIAGS Commands

The DIAGS shell includes factory test commands:

- `audio`, `playaudio`, `recordaudio`, `loopaudio` — audio testing
- `wifi`, `bluetooth` — radio testing
- `sensor`, `temperature` — hardware sensors
- `nandcsid`, `nandppnfwver`, `nanduid` — NAND diagnostics (safe reads; bare `nand` only prints `ERROR: No arguments`)
- **`NANDInfoTool` — DO NOT RUN.** It panics DIAGS (null-pointer dereference in `TestNand.macho`,
  Translation Fault Level 1) and the pod reboots into DFU.
- `help <command>` — prints a command's usage. `temperature`, `sensor`, `wifi`, `bluetooth`,
  `playaudio` and `recordaudio` all need arguments and only print a usage error when typed bare.
- `playaudio` — tone / file playback. From `help playaudio` and `playaudio --listcaps` on a real unit:
  - `playaudio [-b block] [-p port] [-o|--listcaps] [-d 8|16|24|32] [-r rateHz] [-c channels]
    [-t freqHz] [-l lenMs] [-f file] [-u buffer] [-a|--async]`
  - `socmca` is the only block marked playable (8–96 kHz, 8/16/24/32-bit, async). `ampcontroller`,
    `codec0` and `codec1` are 48 kHz / 16-bit only, so tones are generated at `-r 48000 -d 16`.
  - Without `--async` the command blocks until the sound ends; `stopaudio` ends an `--async` session.
  - The app's tone buttons send `ampcontroller --init`, then
    `playaudio -b socmca -t <Hz> -l <ms> -r 48000 -d 16` (Test Tone: 1 kHz for 3 s; Tone Sweep:
    100 Hz, 500 Hz, 1 kHz, 2 kHz, 5 kHz, 10 kHz at 1.5 s each, about 9 s — a seal check: weak or
    rattling bass at 100 Hz means the enclosure leaks).
  - **Not yet confirmed to play.** Port names have not been captured and bare `playaudio` says both
    a block and a port are required, so these port-less lines may only print an error naming the
    port. Record what the shell answers here once they have been run.
- `strobe` — LED control
- `pmustat`, `pmutemp`, `pmureg` — power management
- `sysinfo`, `system`, `version` — system information
- `blockdevice` — storage information

## SEP Diagnosis — Identifying a Dead-SEP Board

A board whose Secure Enclave Processor (SEP) has failed looks healthy in
almost every other way, which makes it easy to waste time on the NAND or the
restore tooling. Diagnose it from the UART log of a restore attempt.

### Signature of a dead SEP

All of these together:

1. **The restore fails at the `load_sep_os` step.** UART shows the restore
   daemon reaching that checkpoint and never finishing it:

   ```
   CHECKPOINT BEGIN: RESTORED:[0x0609] load_sep_os
   restore-step-names = {0x11030609:load_sep_os}
   entering load_sep_os
   entering ramrod_load_sep_os
   ```

2. **The kernel panics with `SEP ROM boot panic`** a few lines later:

   ```
   panic(cpu 1 caller 0x...): "SEP ROM boot panic. 0x55E06991..." @SEPROMPanicBuffer.cpp:71
   ```

3. **`IBFL` (iBoot Flags) increments between attempts.** It is in the
   `USB_SERIAL_NUMBER` line iBoot prints at start-up. On the diagnosed pod it
   read `IBFL:1C` before the failed restore and `IBFL:1D` on the next boot.

4. **DIAGS and SSH ramdisks still boot fine.** Neither brings up the SEP, so
   a pod that boots `diag.img4` and gives a `:-)` prompt but always dies at
   `load_sep_os` during a restore points at the SEP, not at the AP, USB or
   the boot files.

### What it means

The SEP is a coprocessor inside the A8 die, not a separate chip, and its ROM
is mask ROM. **This fault is not repairable** short of replacing the SoC.
Re-running the restore, reflashing, or swapping the NAND will not clear it.
The application processor, NAND, USB, WiFi and audio hardware are unaffected,
which is why such a board is still a candidate for booting Linux (see
`knowledge-transfer.md`).

### Red herrings in the same log

These appear in the log of a dead-SEP restore but are **not** the fault:

- **`ASPBlockStorage::asyncReadWrite - Returning kIOReturnUnformattedMedia`**
  — the NAND simply has not been formatted yet at that point in the restore.
- **`AppleExternalAmpController::receiveSerialEventGated: hw overrun`** — also
  printed on pods that restore and work normally.

### Reference capture

The pod this was diagnosed on (ECID `0000000000000002`, serial
`SERIAL000002`) has its logs saved in the app folder:

- `uartlogduringrestoreattempt.0` — full restore attempt, `iBoot-11881.80.57`,
  `load_sep_os` at line ~1481, panic at line ~1530, `IBFL:1C` then `IBFL:1D`.
- `uartlogbootattempt.0` — the following boot, `iBoot-13822.80.422.0.2`,
  `IBFL:1D`.

## NAND Health Indicators from UART

What the storage lines in a UART log do and do not tell you:

| UART indicator | Meaning | Action |
|----------------|---------|--------|
| `NAND_UNC` on specific blocks | Uncorrectable read errors — those blocks are degrading. A few is a warning, a growing list is a failing NAND. | Note the block addresses and compare across boots. Plan a NAND replacement if they spread. |
| SysCfg reported at location `[255,255]` | The SysCfg partition was not found — missing or corrupted. Identity and calibration are gone from this NAND. | Rewrite SysCfg from a saved `syscfg list` (see [NAND Replacement Workflow](#nand-replacement-workflow)). |
| `ASPStorage::GetNANDGeometry - lbaFormatted : NO` | **Normal** before a restore has formatted the NAND. | None. |
| `kIOReturnUnformattedMedia` | Same cause as above — unformatted, not broken. | None. |

On the dead-SEP pod the session also recorded `NAND_UNC` errors on blocks
`[8,14]` and `[9,15]` and SysCfg at `[255,255]`. Those two lines are not in
the two saved UART logs named above, so re-capture them before relying on the
exact block numbers.

A degraded NAND and a dead SEP can occur on the same board. Fixing the NAND
does not help if the SEP signature above is also present.

## Building iBSS/iBEC from Scratch

See Sammisage's guide in `~/Downloads/diagsstuffnic/`. The pre-built
files work on all HomePod 1st gen units, so building is only needed
if the source ProtoPod dump changes.
