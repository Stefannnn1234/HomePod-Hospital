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
- `nand`, `nandcsid`, `nanduid`, `NANDInfoTool` — NAND diagnostics
- `strobe` — LED control
- `pmustat`, `pmutemp`, `pmureg` — power management
- `sysinfo`, `system`, `version` — system information
- `blockdevice` — storage information

## Building iBSS/iBEC from Scratch

See Sammisage's guide in `~/Downloads/diagsstuffnic/`. The pre-built
files work on all HomePod 1st gen units, so building is only needed
if the source ProtoPod dump changes.
