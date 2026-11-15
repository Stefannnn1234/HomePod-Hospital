# WriteSink architecture — committing SysCfg to a replacement NAND

Status: design + first implementation. Target: AudioAccessory1,1 (A8 / T7000),
audioOS **18.3 / 22K557**. Authoritative RE: `SYSCFG_WRITE_FINDINGS.md`.

This document explains the `WriteSink` abstraction, the read-only `GetLocker`
probe, the firmware-pinning decision, the `syscfg-probe` on-device helper, and the
validation gate that stands between "we think we can write" and actually writing a
customer's chip.

---

## 1. Why an abstraction instead of a sink string

The old transport carried a single `sinkCommand: String` and piped
`base64 | sinkCommand` on stdin. That was a placeholder, and it bakes three wrong
assumptions into the one truly dangerous operation in the app:

1. **There is only one write mechanism.** There are at least two candidates (see
   the RE): the primary `AppleEffaceableStorageUserClient::SetLocker` path, and a
   DIAGS-kernelcache `AppleDiagnosticDataAccess` fallback. They have different
   shapes, different gates, and different risk.
2. **A write is a stdin pipe.** Real writes are "stage a file on the pod, then run
   a tool that reads it." The SysCfg blob is ~128 KiB; its base64 is ~170 KiB,
   which can exceed a single command line's `ARG_MAX`. Writes need a staged file.
3. **"Not the placeholder string" means validated.** It doesn't. A path is only
   safe once it has passed a same-bytes round-trip on real hardware — and that
   fact has to be *remembered*, per mechanism.

`WriteSink` fixes all three. Each write path is an object that knows how to probe
itself (read-only), commit bytes (once validated), and report whether it is
validated. The transport keeps only the generic plumbing and one gate.

### The seam

```
SysCfgJob.restore
      │  writeRawBlob(blob)
      ▼
SSHRamdiskTransport ──(hasValidatedSink?)──► refuse if false
      │  if config.writeSink != nil
      ▼
WriteSink.commit(blob, via: shell)     ← RamdiskShell (run / dumpBinary / stage)
      │  stage(blob) → run on-device tool (syscfg-probe set-locker)
      ▼
AppleEffaceableStorageUserClient::SetLocker (selector 6)
```

`RamdiskShell` is the narrow pod-side interface (`run`, `dumpBinary`, and the new
`stage`/`stagedSize` helpers). A sink is handed a `RamdiskShell`, never the
concrete transport, so sinks are testable against any shell (including a fake) and
stay Foundation-only in `HomePodRestoreCore`.

### Files

| File | Role |
|---|---|
| `WriteSink.swift` (new) | `WriteSinkType`, `WriteSink` protocol, `ProbeResult`, `EffaceableLockerSink`, `DiagsKextSink`, `WriteSinkValidation`, `WriteSinkRegistry`, `EffaceableSelector`, `FourCC`, and the chunked `RamdiskShell.stage` helper. |
| `SysCfgRamdiskTransport.swift` (modified) | `Config.writeSink` + `stageRemotePath`; `hasValidatedSink` wired to `WriteSink.isValidated`; `writeRawBlob` delegates to the sink; `stageFile`/`runSinkTool`/`probeSink` added; write probe updated to look for the effaceable stack first. |
| `SysCfgSession.swift` (modified) | `RamdiskFirmware` pinning namespace; `GasterRamdiskBooter.Config.writeSink` threaded to the transport. |
| `SSHRDBooter.swift` (modified) | `writeSink` threaded through `PreBootedBooter` and `SSHRDBooter`; `SSHRDRamdiskBuilder` default version pinned to 18.3. |
| `ramdisk-overlay/usr/local/bin/hpdiag-getlocker` (new) | Read-only ioreg enumeration of the effaceable stack, emitting JSON. |

---

## 2. The write paths (`WriteSinkType`)

### `effaceableLocker` — PRIMARY
`AppleEffaceableStorageUserClient::SetLocker` (selector **6**). Container-safe: the
storage engine does its own generation/checksum/commit, so a correct call can't
half-corrupt the locker the way a raw `setBytes` could. SysCfg is stored as an
effaceable **locker** keyed by a 4-char `type_id`. This is the same kext Apple
uses for nonce storage, so it is live, not stubbed. The only gate likely to bite
is the SecureRoot trust check on a *protected* locker, which is a one-instruction
`clientHasPrivilege("SecureRoot") → true` kernel patch we already have room for in
the boot chain. Round-trip verifiable, which is exactly what makes it safe to
prove.

### `diagsKext` — FALLBACK
A DIAGS kernelcache carrying a *writable* `AppleDiagnosticDataAccess`. This is
Apple's canonical SysCfg write mechanism, but it's heavier to stand up (needs a
DIAGS kernelcache booted, not the restore one). Used only if the locker is
`private` (driver-only, untouchable from userspace even when trusted). Starts
unvalidated; its `commit` refuses until the path is proven.

### `kernelPatch` — SHELVED (not a case)
The original plan — patch `AppleDiagnosticDataAccessReadOnly::setProperties` and
run base→stage→commit — is **invalid and unsafe on 18.3** and is deliberately not
represented as a selectable sink. The RE found the write stubbed at two vtable
levels (+0x160 and +0x540), the stage/commit path type-confuses an
`OSDictionary`, and there is no data-injection path at all. See
`SYSCFG_WRITE_FINDINGS.md` §"Why the setProperties patch is a dead end". Left in
`WriteSink.swift` only as a commented reminder so nobody re-adds it.

---

## 3. The GetLocker probe (read-only, zero risk)

Discovery is split in two because a POSIX shell cannot make IOKit external-method
calls:

1. **`hpdiag-getlocker`** (shell, in the overlay) runs `ioreg` to answer the cheap
   questions: is `AppleEffaceableStorage` present, is its user client matchable, is
   the DIAGS `AppleNANDConfigAccess` node present, and is `syscfg-probe` installed?
   It emits a single-line JSON object between `HPDIAG_GETLOCKER_BEGIN` /
   `HPDIAG_GETLOCKER_END` sentinels so the Mac side can parse it out of
   banner-polluted SSH output. It writes nothing.

2. **`syscfg-probe`** (arm64 binary, spec below) does the actual IOKit work: open
   the user client, call `GetLocker` (selector **5**) across candidate `type_id`s,
   and report which one holds the SysCfg blob, its class, and its size.

`EffaceableLockerSink.probe(via:)` runs both (the script always, the binary if
present) and folds their JSON into a `ProbeResult`:

```
ProbeResult {
  nodePresent, userClientOpenable        // from hpdiag-getlocker (+ confirmed by probe)
  lockerTypeID, lockerFourCC, lockerSize // from syscfg-probe GetLocker
  lockerClass: normal | protected | private | unknown
  trusted: Bool?                         // SecureRoot trust state of this boot
  matchedExpectedBlob: Bool              // bytes matched the pod's known SysCfg
  raw, notes[]
}
```

Everything in the probe is read-only. It is safe to run on a repair unit with a
blank chip, on a known-good donor, on anything — it is the first, non-destructive
step of the plan and carries no brick risk.

### Candidate `type_id`s

The SysCfg locker tag is the one static unknown left. The sink tries a candidate
list (`SCfg`, `SyCf`, `ScFg`, `Cnfg`, `nvSC` by default), and for each it tries
both the forward spelling and the byte-reversed (little-endian on-flash) spelling
— the SysCfg container signature `SCfg` is stored as `gfCS`, so the locker tag may
be reversed too. The right tag is the one whose `GetLocker` bytes match the pod's
known 131072-byte SysCfg blob (size and/or `SCfg`/`gfCS` signature). Once found,
it is pinned into `EffaceableLockerSink.Settings.confirmedTypeID` and writes
target only that tag.

---

## 4. `syscfg-probe` — on-device arm64 helper (interface spec)

We can't compile an arm64 Mach-O here, but the interface is fixed so the Swift
side and the helper stay in lockstep. It is a tiny statically-linked (or
dylib-light) tool dropped in the ramdisk overlay at
`/usr/local/bin/syscfg-probe`. It makes `IOConnectCallMethod` calls against
`AppleEffaceableStorageUserClient`; it never parses NAND itself.

### Offsets it relies on (from the RE)
`IOExternalMethodArguments`: scalarIn@0x20/cnt@0x28, structIn@0x30/size@0x38,
scalarOut@0x48/cnt@0x50, structOut@0x58/size@0x60. Selectors per
`EffaceableSelector` in `WriteSink.swift` (GetCapacity=0 … SetLockerWithID=11).

### Subcommands

```
syscfg-probe open --json
    Open AppleEffaceableStorage, call getCapacity(0) + isFormatted(3).
    → {"ok":bool,"userClientOpened":bool,"capacity":int,"formatted":bool,
       "trusted":bool,"notes":[...]}

syscfg-probe get-locker --json --candidates <csv-of-uint32> [--expect-size N] \
                        [--type-id <uint32>] [--out <path>]
    For each candidate type_id, call GetLocker(5).
    Report the first whose structOut size (and, if --expect-size, size match)
    looks like SysCfg; optionally write its bytes to --out for the host to diff.
    → {"ok":bool,"userClientOpened":bool,"lockerTypeID":uint32|null,
       "lockerClass":"normal|protected|private|unknown","lockerSize":int|null,
       "trusted":bool,"matchedExpectedBlob":bool,"tried":[{ "typeID":uint32,
       "ret":"0x…","size":int}],"notes":[...]}

syscfg-probe set-locker --json --type-id <uint32> --in <path>
    Read <path>, call SetLocker(6) with scalarIn=type_id, structIn=bytes.
    DESTRUCTIVE. The host only calls this through a validated sink.
    → {"ok":bool,"ret":"0x…","wrote":int,"notes":[...]}

syscfg-probe verify --json --type-id <uint32> --in <path>
    GetLocker(5) and byte-compare against <path>. Read-only.
    → {"ok":bool,"identical":bool,"lockerSize":int,"notes":[...]}
```

### Rules the helper must honour
- All JSON is wrapped in `SYSCFG_PROBE_BEGIN` / `SYSCFG_PROBE_END` sentinels (one
  object between them), matching how the Swift side extracts it.
- Non-zero `IOReturn` is surfaced as the `ret` hex string, never swallowed. An
  `0xe00002xx` "external/untrusted" return on GetLocker is the signal that the
  locker is protected/private and this boot is untrusted.
- `set-locker` must refuse a `type_id` of `0` or the wildcard `0x2a2a2a2a`
  ('****'), and refuse an input whose size doesn't match the locker's capacity.
- The helper makes no policy decisions about *whether* to write — that gate lives
  in the host (`WriteSink.isValidated` + the transport). The helper only executes.

### Trust gate
If GetLocker/SetLocker return untrusted and the locker is `protected`, the boot
kernel needs `clientHasPrivilege(token, "SecureRoot")` forced true — a
one-instruction patch, applied in the ramdisk's kernelcache, well-understood and
far safer than the shelved setProperties cave. `syscfg-probe` reports the trust
state; applying the patch is a boot-chain concern, not the helper's.

---

## 5. Firmware pinning: 18.3, not 17.5

The SSHRD create step used to default to `17.5`. It now defaults to
`RamdiskFirmware.pinnedVersion` = **18.3** (build **22K557**), defined in
`SysCfgSession.swift`.

**Why:** the entire write RE — every address, the 12-entry
`AppleEffaceableStorageUserClient` dispatch table, the selector indices
(GetLocker=5, SetLocker=6), the gate functions (`PE_i_can_has_debugger`,
`clientHasPrivilege("SecureRoot")`), and the locker-class model — was resolved
against the **18.3 / 22K557** kernelcache. A validated write path is only valid on
the build it was validated on. Booting a 17.5 ramdisk to drive an 18.3-validated
write means the on-device kernel doesn't match the RE: selectors, offsets, and the
trust/class behaviour can all differ silently. That is precisely the "guessing at
silicon" the write gate exists to prevent. Pinning also keeps the booted ramdisk,
the shipping restore IPSW (18.3), and the RE on one build, and lets
`WriteSinkValidation.lastValidatedBuild` invalidate cleanly when Apple ships a new
one.

**What changed in code:** `SSHRDRamdiskBuilder(version:)` now defaults to
`RamdiskFirmware.pinnedVersion`.

**Remaining one-line edits in the app layer (not in Core, left to the app owner):**
- `AppModelSysCfg.swift` → `buildSSHRDRamdisk(version: String = "17.5")` should
  become `= RamdiskFirmware.pinnedVersion`.
- `SysCfgSheet.swift` → the helper text "Runs the proven SSHRD create step
  (sshrd.sh ota 17.5)" should read `ota 18.3`.

---

## 6. Validation gate — from "reads back equal" to "safe to ship"

The current `SysCfgJob.restore` already does write → read-back → byte-compare.
That proves the *transport* round-tripped the bytes in one session; it does not
prove the *mechanism* is safe across a reboot or that a pod will activate. The
design adds three layers on top, backed by the new persistence types.

### 6.1 Same-bytes round-trip (the gate that unlocks real writes)
Before any sink may be used to write a *new* chip, it must pass, on a
**known-good pod**:

1. GetLocker read of the pod's own SysCfg (via the probe).
2. SetLocker of **those exact same bytes** back.
3. **Reboot the pod** (cold), re-boot the ramdisk, GetLocker again.
4. Assert byte-identical to step 1.

Only a reboot-surviving round-trip proves SetLocker committed to NAND correctly
(generation/checksum/commit all took), as opposed to a read-back that merely hit a
cache in the same boot. This maps to `WriteSinkValidation.roundTripVerified`, and
`EffaceableLockerSink.isValidated` requires it (plus a `confirmedTypeID`). A sketch
of the orchestration (new `SysCfgJob.Mode.validateRoundTrip` or a dedicated
controller method):

```
read own blob → SetLocker(own) → teardown → reboot pod → reboot ramdisk →
read own blob again → assert identical → mark roundTripVerified = true
```

Until that passes, `writeRawBlob` refuses every real write — the transport gate
and the sink gate both check `isValidated`.

### 6.2 Per-sink validation state persistence
`WriteSinkValidation` records the staircase (userClientOpened → lockerRead →
roundTripVerified → endToEndActivated), when it was last proven, and against which
build. `WriteSinkRegistry` is a Codable `[WriteSinkType: WriteSinkValidation]` the
app persists (e.g. `Application Support/HomePodRestore/write-sinks.json`) with
`load(from:)` / `save(to:)`. On launch the app loads the registry, hydrates each
sink's `Settings.validation`, and only offers "Restore SysCfg" when a sink reports
`isValidated`. A build mismatch (`lastValidatedBuild != RamdiskFirmware.pinnedBuild`)
should drop the sink back to unvalidated and require re-proving — the RE is
build-specific.

### 6.3 End-to-end activation test (confidence, not a precondition)
The strongest signal: after a **real** donor→blank write, let the pod boot
normally and confirm it activates (serial/MAC present, no activation error). This
sets `endToEndActivated`. It is deliberately *not* a precondition for restoring an
owner's own bytes (that's what the round-trip covers), but it's the milestone that
turns "mechanism proven" into "feature proven on a repair unit," and it's recorded
per sink so the app can show how far a path has been taken.

### Do-not-brick rules (enforced by the gates above)
- Never SetLocker before a clean GetLocker round-read on that exact pod.
- Always same-bytes round-trip on a known-good pod before any new-chip write.
- Keep every pod's original 128 KiB blob saved before touching it.
- A sink that isn't `isValidated` can never reach `writeRawBlob` — the transport
  refuses, and `commit` refuses again as defense in depth.

---

## 7. Wiring a validated sink (for when the path is proven)

Once the probe confirms the `type_id` and the round-trip passes, construct a
validated sink and thread it into the live booter (the pre-booted path is the one
the SysCfg restore UI uses):

```swift
var v = WriteSinkValidation()
v.userClientOpened = true
v.lockerRead = true
v.roundTripVerified = true
v.lastValidatedAt = Date()
v.lastValidatedBuild = RamdiskFirmware.pinnedBuild

let sink = EffaceableLockerSink(settings: .init(
    confirmedTypeID: FourCC.value("SCfg"),   // whatever the probe pinned
    validation: v))

let cfg = PreBootedBooter.Config(sshTool: ssh, sshpass: sshpass, writeSink: sink)
let controller = SysCfgController(booter: PreBootedBooter(config: cfg, forwarder: iproxy))
// controller.restore(...) now writes through SetLocker; without a validated
// sink it would refuse at the transport gate.
```

Until that day, every booter defaults `writeSink` to `nil`, the legacy
`sinkCommand` stays the inert `"syscfg_write"` placeholder, and the transport
refuses all writes — reads and the read-only probe are the only live operations.
