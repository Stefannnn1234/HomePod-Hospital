# SysCfg write path — kernelcache RE (AudioAccessory1,1 / A8, 17.5)

Goal: write a saved SysCfg blob back to a replacement NAND so a repaired HomePod
keeps its own identity. Read is proven (ioreg `AppleDiagnosticDataSysCfg`); this
documents the write investigation.

## Source
- Decompressed from `sshramdisk/kernelcache.img4` (LZSS) → 39.6 MB arm64 Mach-O
  (MH_EXECUTE, traditional prelinked kernelcache; not a fileset).

## What the ramdisk exposes (probed live on the pod)
- Only `AppleDiagnosticDataAccessReadOnly` is matched (provider
  `AppleNANDConfigAccess`, under `ASPDiagnostic`/`ASPStorage`). `IOProbeScore` 99.
- `"AppleDiagnosticDataAccess"` is the **match category**, not a separate
  instantiated read-write class.
- **No SysCfg write CLI** on the ramdisk. `restored_external` present is the
  SSHRD ramdisk launcher (prints an "OK" banner, starts dropbear) — NOT Apple's
  restored. `shaihulud` = sandbox-escape + kernel-credentials helper.

## Write mechanism (strong hypothesis, from kernelcache strings/symbols)
- The diagnostics node has **no `IOUserClientClass`** → the write is **not** a
  userclient external method.
- Present: `IORegistryEntryAllowableSetProperties`,
  `IOUserClientDefaultLockingSetProperties`, `IORegistryEntrySetProperties` →
  the write is via **`setProperties` / `IORegistryEntrySetCFProperties`** on the
  node, with a dict `{"AppleDiagnosticDataSysCfg": <blob>}` (symmetric to read).
- Gating entitlement: **`com.apple.system.diagnostics.iokit-properties`**.
- `nand-readonly` is a real PE property with a "Returning readonly" code path —
  prime suspect for whether the node refuses writes. Our SSHRD boot-args include
  `nand-enable-reformat=1 -restore` but not an explicit `nand-readonly=0`.

## Open question (needs decompile to settle)
Does `AppleDiagnosticDataAccessReadOnly::setProperties` allow a write when
`nand-readonly` is clear, or always reject (requiring a different personality to
match)? Locating that override needs the class vtable (OSMetaClass ctor) — a
decompiler pass (none installed in the RE env used; objdump/capstone only).

## Concrete next test (safe, round-trip)
`tools/syscfgset` — a minimal arm64 IOKit tool:
1. `probe` — read the live blob, print size + sig, list node (read-only, safe).
2. `read out.bin` — save the live blob.
3. `write in.bin` — `IORegistryEntrySetCFProperties(node, {SysCfg: in})`, guarded.
Test plan: `read` the blob → `write` the SAME bytes back → reboot & re-read →
confirm serial unchanged and write returned success. If it returns
`kIOReturnNotPrivileged`/`Unsupported`, re-boot with a `nand-readonly=0`-style
boot-arg and retry. Only after a clean same-bytes round-trip do we trust a real
new-chip write (which the app already read-back-verifies).

## CONFIRMED on hardware (round-trip test)
- `syscfgset probe` → `node class: AppleDiagnosticDataAccessReadOnly`, `131072
  bytes, sig gfCS`, `setprops symbol: resolved`.
- `syscfgset write` (same bytes back) → `set result: 0xe00002c4 (device write
  locked)` = `kIOReturnNotWritable`.
- Interpretation: NOT NotPrivileged → the entitlement is honored, `setProperties`
  is the correct write API, and it reached the node's write path. Only blocker:
  the NAND is write-locked.

## Why it's locked (kernelcache strings, ASPStorage)
- `ASPStorage - Ramdisk rooted. Returning readonly` / `ASPIsRootDeviceRamdisk` /
  `Root device is a ramdisk`. ASP forces read-only because we booted from md0.
- The override is `ASPStorage::ASPSetWritable` (asserts `0 != setWritableFlag`,
  else logs "Set writable flag is false"). This is what restored toggles before
  a real SysCfg write.

## Remaining task (well-defined)
Find what sets `setWritableFlag` / how `ASPSetWritable` is invoked — almost
certainly an **ASPUserClient** external method (ASPUserClient is present, 28x).
Then: open ASPUserClient → call SetWritable → retry the SysCfg setProperties
write. Do NOT blind-fuzz userclient selectors on hardware (crash/brick risk);
pin the selector from the kernelcache first.

## Tooling note
`tools/syscfgset` builds for tvOS (Apple TV donor ramdisk): compile against the
tvOS SDK, link only CoreFoundation, resolve IOKit at runtime via dlsym (tvOS SDK
ships no IOKit). Deploy to a tmpfs: `/sbin/mount_tmpfs /mnt1` then scp there.

## SOLVED — the unlock (kernelcache RE via ipsw + disassembly)
ASPSupportNodes kext (0x5c9ac00). Correct code mapping is via the **global**
`__PLK_TEXT_EXEC` segment (the kext-header fileoffs are stale — that was the
earlier blocker). Findings, all address-backed:
- `ASPStorage::setProperties` @ `0xfffffff006c213bc` recognizes the dictionary
  key **`"ASPSetWritable"`** (value an **OSBoolean true** — `OSDynamicCast` to the
  boolean metaclass, `vtable[0x78]`/isTrue). Owning class confirmed `ASPStorage`
  via getMetaClass (vtable[7] @0x6c201fc → gMeta 0x7b69e80, ctor name "ASPStorage").
- Setting it true clears the ramdisk read-only lock (internally `ASPSetWritable`
  @~0x6c2102c sends ASP firmware command opcode 0x81).
- Read-only state is `ASPStorage` flags[0x158] bit 3, set because root is a
  ramdisk (`PE_parse_boot_argn("nand-readonly")` only overrides, doesn't help).

### Recipe (now in tools/syscfgset)
1. `setProperties({"ASPSetWritable": kCFBooleanTrue})` on the **ASPStorage** node.
2. `setProperties({"AppleDiagnosticDataSysCfg": <blob>})` on
   **AppleDiagnosticDataAccessReadOnly** — the write we already proved reaches
   the kernel path; it should now return SUCCESS instead of 0xe00002c4.
`syscfgset writeunlock <blob> --i-understand` does both in order.

## SECOND WALL — the diagnostics node is read-only by class
Hardware test with the ASPStorage unlock: `unlock (ASPSetWritable) -> 0x0
SUCCESS`, but the SysCfg write still returns `0xe00002c4`. RE of the
AppleDiagnosticDataAccessReadOnly kext (__TEXT_EXEC @ 0x6259000) explains why:
- The node's vtable: index **43** = real region read (0x62598ac), index **44**
  = write, which in this class is a 3-instruction stub (`0x6259914`) that
  unconditionally returns `kIOReturnNotWritable` (0xe00002c4).
- So the write refusal is by-design in the `...ReadOnly` class, independent of
  ASPStorage's NAND writability.
- The read-WRITE class `AppleDiagnosticDataAccess` (no "ReadOnly") exists as a
  class string, but the node that instantiates on AppleNANDConfigAccess is the
  ReadOnly variant (it won IOKit matching; ReadOnly IOProbeScore 99).

### Paths forward (open)
1. Make `AppleDiagnosticDataAccess` (RW) instantiate instead of ReadOnly — a
   matching/boot-level change (needs the personalities' gating; likely how a
   real restore gets a writable node). Not a userspace tool tweak.
2. Write the SysCfg NAND region directly now that ASPStorage is unlocked — but
   SysCfg is wear-leveled/scanned (Util_Find_SysCfg), not a fixed offset, so
   this needs the on-NAND format.
The ASPStorage unlock + the read + diagnostics are all solid and shippable; the
SysCfg *write* needs one of the above.

## ASPUserClient — memory-map interface, not method dispatch
ASPUserClient vtable (0x6fbf8c0) overrides only dtor/getMetaClass/free and the
IOUserClient memory/notification methods — **no externalMethod / sMethods
selector table**. clientMemoryForType (vtable[132] @0x6c2c798) dispatches on
memory TYPE, handling `0xe0000010` and `0xe0000100`. So the write path is a
**mapped memory region** (IOServiceOpen ASPUserClient → IOConnectMapMemory
<type>), not an IOConnectCallMethod selector.

### Net picture of the SysCfg write on audioOS 17.5
Guarded at every userspace layer we tried:
- diagnostics setProperties (index 44) = hardcoded NotWritable; no RW node.
- provider AppleNANDConfigAccess kext = thin shell (stub methods).
- ASPUserClient = memory-map interface, no method selectors.
Remaining real options: (a) map an ASPUserClient memory region (0xe0000010 /
0xe0000100) and write the config region directly — still subject to the
wear-leveled on-NAND SysCfg format; (b) a kernelcache patch to re-enable the
ReadOnly node's write (we build the ramdisk kc anyway); (c) the concrete method
from someone who's done a HomePod NAND swap.

## CORRECTION — ASPUserClient has no write path
Re-disassembled fully: the vtable[132] function (0x6c2c798) is `message()`, not
`clientMemoryForType`. The values 0xe0000010 / 0xe0000100 are IOMessage codes
(kIOMessageServiceIsRequestingClose / kIOMessageServiceIsTerminated), confirmed
by the log strings. ASPUserClient overrides only dtor/getMetaClass/free/message/
start — **no externalMethod and no mappable memory**. It's a lifecycle userclient.
So there is NO userspace SysCfg write on audioOS 17.5 via ASPUserClient either.

### Final conclusion
Every userspace IOKit avenue is closed on this firmware:
- diagnostics setProperties = hardcoded NotWritable; no read-write node exists.
- provider kext = thin shell.
- ASPUserClient = lifecycle only.
The write logic (stage regions @0x6259804 + commit @0x62598ac + region write
@0x6259608) EXISTS in the diagnostics kext but is not reachable from userspace
(setProperties, the only entry, is the NotWritable stub). Reaching it needs a
**kernelcache patch** (we already build/patch the ramdisk kc) to route
setProperties to the stage+commit flow — a real patch-dev task with brick risk,
to be validated with same-bytes round-trips first — or the concrete method from
someone who has done a HomePod NAND swap.

## WRITE PATH SOLVED — kernelcache patch (tools/kc-syscfg-patch)
The write functions all exist; only the orchestration was removed. The write
path `regionIO` (0x6259608 @0x62596cc) calls `getProperty(regionName)` then
`node->vtable[0x540]` to write NAND — i.e. it writes the STORED property. So a
working setProperties is just: base_setProperties(store) → stage(mark dirty) →
commit(write). Confirmed slot 44 = setProperties (ASPStorage's slot 44 is the
ASPSetWritable handler). Key addresses (tvOS 17.5 AppleTV kc):
- base IORegistryEntry::setProperties = 0xfffffff00774178c
- stage  = 0xfffffff006259804
- commit = 0xfffffff0062598ac
- NotWritable stub (slot 44) = 0xfffffff006259914  (805880520000bc72c0035fd6)
- code cave (80 zero bytes) = 0xfffffff005d02208

Patch = trampoline the stub to a 72-byte glue in the cave that calls the three
functions and returns 0. A8 has no PAC, so plain-VA patching is valid. Patcher
(`tools/kc-syscfg-patch/patch.py`) verifies the stub bytes + empty cave before
writing. Validate with a same-bytes round-trip (read own SysCfg → patched boot →
write back → reboot → re-read, serial unchanged) before any real new-chip write.
