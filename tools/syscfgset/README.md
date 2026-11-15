# syscfgset — SysCfg write probe (A8 HomePod)

Tests the write hypothesis from `docs/syscfg-write-re.md`: writing the SysCfg
blob back via `IORegistryEntrySetCFProperties` on the diagnostics node.

## Build (on the Mac, needs Xcode + iOS platform)
    ./build.sh            # → ./syscfgset (arm64 iOS, ad-hoc signed w/ entitlements)

## Deploy + test on a pod booted into the SSH ramdisk
    scp -P 2222 syscfgset root@127.0.0.1:/tmp/
    ssh -p 2222 root@127.0.0.1 'shaihulud /tmp/syscfgset probe'         # read-only
    ssh -p 2222 root@127.0.0.1 'shaihulud /tmp/syscfgset read /tmp/sc.bin'

## The safe first write: same-bytes round-trip (no identity change)
    ssh -p 2222 root@127.0.0.1 'shaihulud /tmp/syscfgset write /tmp/sc.bin --i-understand'
Then **reboot the pod and re-read** — confirm the serial is unchanged and the
call returned SUCCESS. That proves the write mechanism with zero risk.

- SUCCESS on the round-trip → the write path works; wire this sink into the app.
- `0xe00002c7` (kIOReturnNotPrivileged) → entitlement/creds issue; shaihulud
  should cover it, else investigate signing.
- `0xe00002c2`/unsupported, or no change after reboot → the ReadOnly node rejects
  writes; re-boot with a `nand-readonly=0` boot-arg and retry (see the RE doc).

Run under `shaihulud` for the kernel credentials the entitlement path needs.
