# syscfg_write — HomePod SysCfg writer (diags path)

Writes a SysCfg region to a HomePod's NAND through Apple's own writable
diagnostics driver (`AppleDiagnosticDataAccess`), the way the factory diags
image does. For legitimate repair: restoring a repaired board's **own** factory
identity (serial, Wi-Fi/BT MAC, region, housing color) after a NAND replacement.

## Where this runs

NOT on stock firmware. Stock/production firmware ships only the ReadOnly
diagnostics class, and the provider's write method is a `kIOReturnUnsupported`
stub. The writable class exists only in internal/diags builds. So this tool runs
on a **booted 11.2 diags kernel** (checkm8), after the writable kext is loaded:

```
# on the diags ramdisk, as root:
kextload /path/to/AppleDiagnosticDataAccess.kext   # provides the writable node
./syscfg_write info                                 # confirm "writable node: PRESENT"
```

## The IOKit contract (reverse-engineered from the driver)

`setProperties` on the `AppleDiagnosticDataAccess` service, caller must be root:

| key                          | type      | meaning                               |
|------------------------------|-----------|---------------------------------------|
| `AppleDiagnosticDataSet`     | OSString  | region name (`AppleDiagnosticDataSysCfg`) |
| `AppleDiagnosticDataOffset`  | OSNumber  | byte offset into the region           |
| `AppleDiagnosticDataBuffer`  | OSData    | bytes to write                        |
| `AppleDiagnosticDataCommit`  | OSBoolean | true = flush region to NAND           |

Internally: `setProperties -> _writeBuffer` (copies into the cached region
buffer) `-> _writeRegion -> AppleEffaceableStorage::setBytes` (the real NAND
write). Reads come back from the read-only property `AppleDiagnosticDataSysCfg`.

## Usage

```
syscfg_write info
syscfg_write read   syscfg out.bin
syscfg_write write  syscfg new_syscfg.bin [--offset N] [--commit --i-understand]
syscfg_write verify syscfg expected.bin
```

- `write` is a **dry run by default** — it stages the bytes into the driver's
  buffer but does NOT flush to NAND. You must pass **both** `--commit` and
  `--i-understand` to actually write.
- `<region>` accepts `syscfg`, `display`, or a literal `AppleDiagnosticData*`
  name.

## Recommended procedure (same-bytes round trip first)

1. `syscfg_write read syscfg pod_syscfg.bin` — save the current region.
2. `syscfg_write write syscfg pod_syscfg.bin` — dry run, expect `setProperties OK — staged only`.
3. `syscfg_write write syscfg pod_syscfg.bin --commit --i-understand` — write the
   pod's *own* bytes back (a no-op change, safe validation of the write path).
4. Reboot, `syscfg_write read syscfg check.bin`, confirm it matches — proves the
   write path is real before you ever write a *new* identity to a blank NAND.

## Error codes

- `0xe00002c1` kIOReturnNotPrivileged — not running as root.
- `0xe00002c4` kIOReturnNotWritable — hit the ReadOnly node; the writable kext isn't loaded.
- `0xe00002c7` kIOReturnUnsupported — provider write path absent; not a diags kernel.

## Build

`./build.sh` on macOS with Xcode (targets iPhoneOS arm64, iOS 11.2 min).
