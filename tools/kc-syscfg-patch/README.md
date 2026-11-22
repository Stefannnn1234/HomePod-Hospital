# kc-syscfg-patch — re-enable SysCfg write (A8 HomePod ssh-ramdisk kernelcache)

Re-enables writing SysCfg on audioOS/tvOS **17.5** (AppleTV donor kernelcache).
Full RE background in `../../docs/syscfg-write-re.md`.

## The problem
`AppleDiagnosticDataAccessReadOnly::setProperties` (vtable slot 44) is a
3-instruction stub returning `kIOReturnNotWritable` (0xe00002c4). There is no
read-write node on this firmware. But the write machinery still exists in the
same kext:
- `stage`  @`0xfffffff006259804` — marks the region dirty for each region name in the dict
- `commit` @`0xfffffff0062598ac` — for each dirty region, `regionIO` **reads the stored
  property** (`getProperty(regionName)`) and writes it to NAND (`node->vtable[0x540]`)
- base `IORegistryEntry::setProperties` @`0xfffffff00774178c` — stores the dict

The writable `setProperties` the RW class would have had is simply:
`base_setProperties(dict); stage(dict); commit(dict)`. ReadOnly replaced it with
the refusal stub.

## The patch
Turn the stub into a trampoline to a 72-byte glue routine in a `__PLK_TEXT_EXEC`
code cave (`0xfffffff005d02208`, verified 80 zero bytes):

    setProperties_patched(this, dict):
        base_setProperties(this, dict)   ; store the dict (incl. AppleDiagnosticDataSysCfg)
        stage(this, dict)                ; mark the SysCfg region dirty
        commit(this, dict)               ; regionIO reads stored prop, writes NAND
        return 0

- `0xfffffff006259914`: `b 0xfffffff005d02208` (overwrites the stub's first 4 bytes)
- `0xfffffff005d02208`: the glue (reuses existing functions via BL)

The patcher verifies the exact stub bytes (`805880520000bc72c0035fd6`) and that the
cave is empty before writing — it refuses on any other firmware.

## Usage
    # 1) Decompress the ramdisk kernelcache to a raw arm64 Mach-O
    python3 -m pyimg4 im4p extract -i ~/SSHRD_Script/sshramdisk/kernelcache.img4 -o /tmp/kc.raw
    # (if it's an .img4: `pyimg4 img4 extract -i kernelcache.img4 -p /tmp/kc.im4p` first)
    # 2) Apply the SysCfg-write patch
    python3 patch.py /tmp/kc.raw /tmp/kc.patched
    # 3) Repack as rkrn img4 with the generic IM4M and rebuild the ramdisk
    #    (same IM4M SSHRD uses: img4tool -e -s other/shsh/0x7000.shsh -m /tmp/IM4M)
    img4 -i /tmp/kc.patched -o ~/SSHRD_Script/sshramdisk/kernelcache.img4 -M /tmp/IM4M -A -T rkrn

NOTE: this patched kernel must ALSO carry KPlooshFinder's AMFI patches (so the ssh
tools run). Easiest: run `patch.py` on the kernel AFTER KPlooshFinder has patched
it, then pack once. A8 has no PAC enforcement, so the plain-VA vtable/branch patch
is valid as-is.

## VALIDATION (do this before trusting any real write)
The patch is sound by construction (reuses the real write functions), but it
writes NAND, so prove it harmlessly first:
1. `syscfgset read /mnt1/sc.bin`            — save the pod's OWN SysCfg
2. boot the PATCHED ramdisk
3. `syscfgset write /mnt1/sc.bin --i-understand`  — expect `set result: 0x0 SUCCESS`
4. reboot, `syscfgset read` again, confirm the serial is UNCHANGED (SERIAL000001)
Writing the pod's own bytes can't change its identity, so a clean round-trip
proves the mechanism with zero risk. Only then write a saved dump to a new chip.
