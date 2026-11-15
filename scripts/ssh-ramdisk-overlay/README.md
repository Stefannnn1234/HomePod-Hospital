# HomePod ramdisk diagnostics overlay (`hpdiag-*`)

Read-only diagnostic scripts for the HomePod Restore SSH ramdisk (1st-gen HomePod,
A8, booted via checkm8). They run **on the HomePod** and are called by the macOS app
through `RamdiskShell.run("hpdiag-nand")` etc.

Nothing here writes to NAND. Every probe is an `ioreg` query or a `dd` read.

## Output contract

Each script prints exactly one JSON object on one line, framed by sentinels:

```
===HPDIAG_JSON_BEGIN===
{"tool":"nand","ok":true,"verdict":"pass", ...}
===HPDIAG_JSON_END===
```

Common keys in every object:

| Key | Meaning |
|-----|---------|
| `tool` | short tool name (`nand`, `partmap`, `factory`, `thermal`, `power`, `radio`, `audio`, `sensors`, `mic`, `accel`, `full`) |
| `ok` | `true` if the tool ran and found the data it looks for; `false` if the source node/tool was missing |
| `verdict` | `pass`, `warn`, `fail` or `info` (`info` = nothing to judge, see `note`) |
| `note` | human-readable notes joined with `; ` (omitted when empty) |
| `error` | only when a prerequisite is missing (e.g. no `ioreg`) |
| `raw` | uninterpreted source text, capped at 6000 bytes (`HPDIAG_RAW_MAX` to change) |

A key is **omitted** when its value is unknown; it is never `null`. Numbers are JSON
numbers when the source value is plain decimal, strings otherwise. All text is reduced
to printable ASCII before it is embedded, so the JSON is always valid.

## Scripts

| Script | What it does | Main keys | Verdict |
|--------|--------------|-----------|---------|
| `hpdiag-partmap` | Maps each region to its device by IOMedia name (`ioreg -r -c IOMedia`: "Apple NAND/Firmware/LLB/PanicLog Media" -> `BSD Name`) - device numbers are **not** fixed (real pod: disk2 = Firmware, disk3 = LLB, disk4 = PanicLog). Enumerates `/dev/rdisk*` and `/dev/disk*`, reads 1 MiB from each, sniffs magic. The firmware and LLB regions are scanned for img4 tags (`IM4P`/`IMG4`) and LLB/iBoot markers; the panic-log region is checked for content. Without an ioreg map only disk0 = NAND / disk2 = Firmware are assumed. | `devices[{dev,node,media,role,readable,bytes,type,magic,empty,markers,img4,bootStrings}]`, `mapSource`, `mediaMap[{bsd,media}]`, `nandDevice`, `firmwareDevice`, `llbDevice`, `panicDevice`, `expectedPresent`, `firmwareValid`, `llbValid`, `panicLogHasPanic` | `fail`: no devices, or the main NAND device missing/unreadable. `warn`: a named region (NAND/Firmware/LLB/PanicLog) missing, a device unreadable, no img4 magic in the firmware region, panic text in the panic-log region. |
| `hpdiag-nand` | Reads the properties the A8 ASP really publishes: `ASPStorage` `AppleNANDStatus`, `Device Characteristics`, `Controller Characteristics`, plus `IOBlockStorageDriver` `Statistics` (error/retry counts) per whole disk. This ASP exposes no wear/spare/bad-block/erase counters in the IORegistry. | `source`, `nandStatus`, `encryptionType`, `nandMarketingName`, `vendor`, `chipId`, `manufacturerId`, `firmwareVersion`, `capacityBytes`, `caus`, `blocksPerCau`, `blocksTotal`, `packageBlocksAtEOL`, `pagesPerBlockMlc/Slc`, `bitsPerCell`, `disks[{bsd,media,errorsRead/Write,retriesRead/Write,opsRead/Write,bytesRead}]`, `mainDisk`, `ioErrorsRead/Write`, `ioRetriesRead/Write`, `readRetrySeen`, `writeLocked`, `ramdiskRooted` | `fail`: `AppleNANDStatus` not `Ready`, main NAND disk has I/O errors, or no NAND at all. `warn`: main NAND disk has retries, or the status property is missing. `pass` otherwise. Errors on other regions (e.g. PanicLog) are noted only. |
| `hpdiag-factory` | Reads the SysCfg blob from `AppleDiagnosticDataAccessReadOnly` and checks identity tags `SrNm`, `WMac`, `BMac`, `EMac`, `Mod#`, `Regn`, `RMd#`, `MLB#` and calibration tags `SpEQ`, `SpGa`, `WFEQ`, `MiGa`, `WCAL`, `BCAL`, `LEDc`, `LSCI`, `MdlC`. Detects the `AppleDiagnosticData` iPCB factory station log (provenance, never affects the verdict). Lists `AppleEffaceableStorage` properties. | `sysCfgSig`, `sysCfgBytes`, `tagsPresent`, `tagsMissing`, `tagsExpected` (17), `identityTagsPresent/Expected`, `calibrationTagsPresent/Expected/Missing`, `diagData{present,sig,bytes,blank}`, `serial`, `lockers` (always `[]`), `effaceable`, `sysCfgHead` | `fail`: serial, MLB, Wi-Fi or BT MAC tag missing. `warn`: any other tag missing, bad signature, empty blob. |
| `hpdiag-thermal` | Names-only node walk for thermal sensor nodes, plus properties of `ASPTemperatureSensor`, `IOPMrootDomain` and `AppleARMPMU` only. On a real pod the one sensor ("NAND CH0 temp") is a HID service with no static reading. | `uncalibrated:true`, `sensors[{name,raw,calibrated:false}]`, `nodes`, `rootDomain`, `pmu` | Always `info`. Values are raw counts, not degrees C. |
| `hpdiag-power` | Properties of `IOPMrootDomain` and `AppleARMPMU` (those nodes only); PMU/charger/power-source nodes from a names-only walk; rail-looking properties and boot flags from the PMU node. | `pmu{node,rails[{name,mv,unit}],bootFlags,properties}`, `rootDomain`, `nodes` | `pass`: PMU node found. `warn`: root domain but no PMU. `info`: neither. |
| `hpdiag-radio` | Wi-Fi and Bluetooth nodes (names-only walk), attached `AppleBCM*` driver, MACs from the `wlan` / `bluetooth` device-tree nubs only, compared against SysCfg `WMac`/`BMac`. | `wifi{present,driver,mac,matchesSysCfg,nodes}`, `bt{...}` | `pass`: both radios have drivers and MACs match. `warn`: a radio missing, only one driver up, MAC blank or different from SysCfg. `info`: nodes present but no drivers loaded. |
| `hpdiag-audio` | Codec, amp, speaker and I2S/MCA nodes from a names-only walk (no property is read). Presence only, no sound. | `codecDetected`, `ampNodes`, `amps` (always `[]`), `audibleTest:false`, `endpoints`, `driversAttached`, `nodes` | `pass`: a codec or amp node enumerates. `info`: otherwise. |
| `hpdiag-sensors` | AOP, microphone, voice-trigger and accelerometer nodes from a names-only walk (no property is read). Presence only. | `aop{present,nodes}`, `mic{detected,aopNode,capture:false,nodes}`, `accel{detected,liveSampling:false,nodes}` | Always `info`. |
| `hpdiag-mic`, `hpdiag-accel` | Two-line wrappers for `hpdiag-sensors mic` / `hpdiag-sensors accel`; same data, flat, with `tool` set to `mic` / `accel`. | as above, flat | Always `info`. |
| `hpdiag-full` | Runs everything above once and assembles one report. | `serial`, `timestamp`, `overall`, `counts`, `summary{tool:verdict}`, `tools[...]` | `overall` (and `verdict`): any `fail` -> `fail`, else any `warn` -> `warn`, else `pass`. `info` results are neutral; if no tool reached a judgement the result is `warn`. |

## What is and is not confirmed

## ioreg rules (every script)

**Never run `ioreg -l` (or `ior -l`) on the ramdisk.** Dumping the whole registry
with properties makes the kernel serialise every driver's properties and
kernel-panics the pod. Only two forms are used:

- `nodetree <Class>...` - names only. `ioreg -r -c <Class>` **without** `-l` prints
  just the `+-o name <class ...>` lines of each matching subtree and reads no
  property. Used for all node discovery.
- `ior -r [-d 1] -c <Class> -l` - properties of one specific class (`-d 1` = that
  node only, not its children). `hpdiag-radio` also reads the `wlan` / `bluetooth`
  device-tree nubs by name (`-p IODeviceTree -r -d 1 -n <name> -l`).

All ioreg calls go through the `ior` wrapper, which adds `-w 0` and strips the ANSI
colour escapes this ramdisk's ioreg emits even into a pipe:

```sh
ESC=$(printf '\033'); ior() { ioreg -w 0 "$@" 2>/dev/null | sed -e "s/${ESC}\[[0-9;]*m//g"; }
```

## What is confirmed, and what is not

Tested on Linux (dash and bash) against a replay of a **real pod's** targeted ioreg
capture (AudioAccessory1,1, stock SSH ramdisk). That capture is storage-scoped, so:

- **Confirmed on hardware data:** `hpdiag-nand`, `hpdiag-partmap` (media map),
  `hpdiag-factory`, the `ASPTemperatureSensor` part of `hpdiag-thermal`, the
  `IOPMrootDomain` part of `hpdiag-power`, `hpdiag-getlocker`.
- **NAND.** The A8 ASP publishes **no** wear / spare-block / bad-block / erase-count
  / uncorrectable counters. `hpdiag-nand` reports what exists: `ASPStorage`
  `AppleNANDStatus` ("Ready"), the `Device Characteristics` dictionary (`vendor-name`,
  `nand-marketing-name`, `chip-id`, `capacity`, `caus`, `blocks-per-cau`,
  `package_blocks_at_EOL`, `pages-per-block-mlc`, `#page-bytes`, ...),
  `Controller Characteristics` (`Encryption Type`), and `IOBlockStorageDriver`
  `Statistics` (`Errors (Read)`, `Errors (Write)`, `Retries (Read)`, ...) per disk.
- **Device numbers are not fixed.** On the captured pod disk2 = Firmware, disk3 = LLB,
  disk4 = PanicLog. Regions are always found by IOMedia name.
- **Not yet confirmed on a pod:** the names-only node walk itself (it reads no
  properties, which is what the panic is tied to, but it has not been run on
  hardware), the `AppleARMPMU` query, and the node-name patterns for PMU, radio,
  audio, mic and accelerometer nodes. Tune the `nodes_json '...'` expressions after
  the first real run - from the names-only output, not from a full dump.
- **DIAGS kernelcache boot.** `hpdiag-factory` / `hpdiag-radio` fall back to the
  writable `AppleDiagnosticDataAccess` class when the `...ReadOnly` one is absent, and
  `hpdiag-getlocker` reports `diagsKextWritablePresent` / `diagsToolInstalled`
  (`/diags/syscfg_write`). Whether the 11.2 DIAGS ramdisk has `ioreg` and publishes
  the same properties is untested.
- **Units.** Thermal values and PMU rails are reported raw (`calibrated:false`,
  `unit:"raw"`); the `mv` key is only a name until the unit is confirmed.
- **Lockers.** Enumerating effaceable lockers needs an IOKit user-client call, which
  `sh` cannot make, so `lockers` is always `[]`.

## Assumptions about the ramdisk

Needs `sh`, `ioreg`, `dd`, `grep -o/-E`, `sed`, `awk`, `tr`, `head -c`, `cut`, `sort`,
`wc`, and `hexdump` (falls back to `od`). `timeout` is used for `dd` if present. No
temp files are written. `strings` and `img4tool` are not required.

`dd` is called with `bs=1048576` rather than `bs=1m` so it works with both BSD and
GNU `dd`; the block size is the same.

Tunables (environment): `HPDIAG_RAW_MAX` (bytes of raw text per tool, default 6000),
`HPDIAG_FW_SCAN_MB` (MiB of `rdisk2` scanned, default 4), `HPDIAG_DD_TIMEOUT`
(seconds, default 20, only if `timeout` exists).

## Adding the scripts to the ramdisk

The tree mirrors the ramdisk root, so it merges straight into the existing SSH
ramdisk overlay (`scripts/ssh-ramdisk-overlay/`, injected by `build-ssh-ramdisk.sh`):

```sh
# from the app repo
ditto /path/to/ramdisk-overlay/usr/local/bin scripts/ssh-ramdisk-overlay/usr/local/bin
chmod 755 scripts/ssh-ramdisk-overlay/usr/local/bin/hpdiag-*
./scripts/build-ssh-ramdisk.sh        # rebuild the ramdisk as usual
```

Do not copy this `README.md` into the ramdisk. Files must stay mode 755 with LF line
endings. `hpdiag-full`, `hpdiag-mic` and `hpdiag-accel` look for their siblings in
their own directory first, then on `PATH`.

To try a changed script without rebuilding, pipe it over the existing SSH session:

```sh
ssh root@<pod> 'sh -s' < usr/local/bin/hpdiag-nand
```

(`hpdiag-full` and the two wrappers need the other scripts installed, so they cannot
be tested this way.)

## Editing

Each script is standalone: the helper block between `shared helpers` and
`end shared helpers` is duplicated in every file on purpose. If you change a helper,
change it in all of them. Keep the scripts POSIX `sh` (they are checked with `dash`).
