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
| DIAGS Config | Serial (UART) | SysCfg writing, NAND replacement, factory provisioning |

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
| `SrNm` | Serial number | CC4VKKTQHQK8 |
| `MLB#` | MLB serial | CC4741500NYJK2N1K |
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
syscfg add SrNm CC4VKKTQHQK8
syscfg add MLB# CC4741500NYJK2N1K
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

## Building iBSS/iBEC from Scratch

See Sammisage's guide in `~/Downloads/diagsstuffnic/`. The pre-built
files work on all HomePod 1st gen units, so building is only needed
if the source ProtoPod dump changes.
