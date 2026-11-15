# HomePod NAND Replacement — SysCfg Write: State Analysis & Implementation Plan

Target: 1st-gen HomePod (AudioAccessory1,1 / A1639 / A8-T7000, board b238aAP).
Scope: completing the **write** side of SysCfg so a blank replacement NAND gets the
unit's own serial / Wi-Fi MAC / BT MAC and the pod can activate.

---

## 0. Executive summary

- **Reading SysCfg is DONE and hardware-verified.** The app boots a checkm8 SSH
  ramdisk, reads `AppleDiagnosticDataSysCfg` out of the IORegistry, decodes the
  131072-byte `gfCS` blob (serial `CC4VKKTQHQK8`, 3 MACs, MLB, model, region),
  and keeps the raw bytes verbatim for write-back.
- **Writing SysCfg is NOT done, and is correctly gated off** in the shipping code
  (`hasValidatedSink == false` for the placeholder sink → `writeRawBlob` throws).
  All the orchestration around the write (validate → write → read-back → byte-compare)
  is built and unit-tested; only the actual on-device *sink* (the thing that
  commits bytes to NAND) is missing.
- **The blocker is a single, well-characterized unknown:** every user-space IOKit
  path on the restore/diagnostics firmware refuses the write by design. Three
  candidate mechanisms have been reverse-engineered to different depths. The docs
  disagree with each other because they were written against **three different
  firmware builds** — this is the single most important thing to fix before more
  engineering.
- **Recommended path:** stop writing against whatever firmware is convenient and
  **pin ONE firmware for the write ramdisk**, then pursue the
  `AppleEffaceableStorage` `SetLocker` path (newest RE, smallest patch, container-safe)
  as primary, with the **Diags writable-kext** path (`diags_boot.sh`) as the proven-shaped
  fallback. Both must be gated behind a same-bytes round-trip on a known-good pod.

---

## 1. Current state analysis

### 1.1 What works (built + hardware-confirmed)

| Capability | Where | Status |
|---|---|---|
| checkm8 unlock + SSH ramdisk boot on the pod | `SSHRDBooter` (in-app gaster→irecovery chain), `PreBootedBooter` (tech boots it, app connects), `GasterRamdiskBooter` (ra1nsn0w, legacy) | Read path proven on-device |
| SysCfg **read** via IORegistry | `SSHRamdiskTransport.readRawBlob` → `extractIORegHexProperty("AppleDiagnosticDataSysCfg")` | **Confirmed**: 131072 bytes, sig `gfCS` |
| SysCfg **parse** (display + sanity only) | `SysCfg.swift` / `SysCfgParser` | Carves `SrNm`/`WMac`/`BMac`/`Mod#`/`Regn`/`RMd#` (reversed FourCC, value-until-NUL, cap 50). Raw bytes retained so a mis-parse can't corrupt a write |
| Read-only diagnostics pull (panic log `dd if=/dev/rdisk3 bs=1m`, `ioreg -l`, write-facility probe) | `DiagnosticsController`, `SSHRamdiskTransport.writeProbeCommand` | Built; low risk; enumerates `AppleNANDConfigAccess` / `AppleEffaceableStorage` nodes + candidate CLIs |
| Write **orchestration + safety** (validate signature + essential tags → write → read-back → refuse on mismatch) | `SysCfgJob.run` (`.restore`), `SysCfgController.restore` | Built, unit-tested with `FakeSysCfgTransport` |
| Write **transport plumbing** (base64 → `sinkCommand` over SSH) | `SSHRamdiskTransport.writeRawBlob` | Built but **gated** — see below |
| SSH-ramdisk build pipelines | `SSHRamdiskBuilder` + `build-ssh-ramdisk.sh` (AppleTV donor), `SSHRDRamdiskBuilder` (drives d235j `sshrd.sh`) | Build logic present; overlay/key notes flagged as unproven |

### 1.2 What is deliberately blocked

`SSHRamdiskTransport.hasValidatedSink` returns false whenever the sink is empty,
whitespace, or the literal placeholder `"syscfg_write"`. The default sink in
**every** booter (`SSHRamdiskTransport.Config`, `PreBootedBooter`, `SSHRDBooter`,
`GasterRamdiskBooter`) is exactly `"syscfg_write"`, so `writeRawBlob` always throws
the "write mechanism isn't validated yet" error. **This is correct and intentional** —
nothing can brick a repair unit today. Completing the feature = proving a real sink
and setting that string (plus, see §3, likely changing the transport's command shape).

### 1.3 The three conflicting write investigations (root cause of confusion)

The repo contains three *different* reverse-engineered write mechanisms, each tied
to a different firmware. They are not alternatives written at the same time; they
are an evolving investigation, and **the newest supersedes the oldest**:

1. **`syscfg-write-re.md` (firmware 17.5)** — walks from "`setProperties` is the write
   API" → hit `kIOReturnNotWritable (0xe00002c4)` → unlocked ASP with
   `setProperties({"ASPSetWritable": true})` on the `ASPStorage` node → **still**
   `0xe00002c4` because the diagnostics node's vtable **slot 44 (write) is a hard
   stub** in the `...ReadOnly` class. Concludes with "**WRITE PATH SOLVED —
   kernelcache patch**" (`tools/kc-syscfg-patch`): trampoline the stub to glue that
   calls `base setProperties → stage → commit`.

2. **`SYSCFG_WRITE_FINDINGS.md` (firmware 18.3, dated Nov 12 — MOST RECENT)** —
   **explicitly invalidates** that kernelcache patch on 18.3: the write functions are
   **double-stubbed** (both `setProperties` +0x160 and the low-level region write
   +0x540 return errors), `stage`/`commit` expect a *request* object not the
   `setProperties` dict (→ type confusion / brick), and there is **no data-injection
   path** (the write-primitive writes pre-loaded region fields, nothing loads new
   bytes). Verdict: **"Do not flash the base+stage+commit patch."** It then RE's the
   **correct** mechanism: `AppleEffaceableStorageUserClient` with a full 12-selector
   dispatch table — `SetLocker` (sel 6) / `GetLocker` (sel 5) operate by 4-char
   locker tag, container-safe, needing **at most one** `clientHasPrivilege("SecureRoot")
   → true` patch.

3. **`SSHRD_Script/diags_boot.sh` (firmware 11.2.5 DIAGS)** — a *third* path not
   reflected in either findings doc: boot an **older Diags kernelcache** (patched,
   `amfi_get_out_of_my_way=1 cs_enforcement_disable=1`), `kextload` a **writable
   `AppleDiagnosticDataAccess.kext`** (the non-ReadOnly class), then run an on-pod
   `syscfg_write` tool. This matches the Apple Wiki's canonical statement that
   SysCfg "can be modified and reflashed using Diags."

**None of the three on-pod write tools referenced by the docs are present in the
upload** — `tools/syscfg_write/`, `tools/kc-syscfg-patch/`, and `tools/syscfgset/`
are named in docs/`diags_boot.sh` but only `Sources/` ships here. So the write RE is
documented but the implementing tools are either not written yet or not staged.

### 1.4 External validation (web research)

- The Apple Wiki and iPhone Wiki both describe SysCfg as **a NAND partition** (a
  dictionary of 4-byte keys: `SrNm`, `WMac`, `BMac`, `EMac`, `Regn`, `SwBh`),
  modified/reflashed by the AppleInternal **Diags** image, or — per both wikis — by
  a "skilled programmer [using] a jailbreak [to] write a custom controller around
  the partition." Changes are **permanent**.
  ([Apple Wiki](https://theapplewiki.com/wiki/SysCfg), [iPhone Wiki](https://www.theiphonewiki.com/wiki/SysCfg))
- **MagicCFG/MagicCFG-Reloaded** (the main open-source SysCfg writer) works over
  checkm8/gaster but **ships no Diags boot files** — the author says you must add
  them yourself, and its device table doesn't include the HomePod's board. So it
  confirms the mechanism (Diags + checkm8) but is **not** plug-and-play for a pod.
  ([MagicCFG-Reloaded](https://github.com/j4nf4b3l/MagicCFG-Reloaded),
  [iFixit on the tiny purple app](https://www.ifixit.com/News/41676/the-tiny-purple-app-that-might-make-iphone-hardware-repair-easier))
- The checkm8 HomePod **ramdisk + SSH** workflow itself is well-trodden (Elcomsoft's
  HomePod forensics work boots exactly this way), but public writeups stop at
  *reading* — nobody documents writing SysCfg back to a pod.
  ([Elcomsoft HomePod forensics II](https://blog.elcomsoft.com/2023/03/homepod-forensics-ii-checkm8-and-data-extraction/))
- Important nuance the web surfaced: the wikis call SysCfg a **NAND partition**, and
  do **not** describe it as an effaceable-storage locker. The `SetLocker` hypothesis
  in `SYSCFG_WRITE_FINDINGS.md` is a strong RE lead **but is not independently
  corroborated** — it must be confirmed on-device (which that doc already plans via a
  read-only `GetLocker` probe). Treat it as the leading hypothesis, not a settled fact.

---

## 2. Technical gaps

1. **No validated write sink.** The one missing string. Everything upstream is ready.
2. **Firmware is not pinned for the write ramdisk.** 17.5 vs 18.3 vs 11.2.5 across the
   docs. The RE is only valid for the firmware actually booted. The repair/restore
   product ships **18.3**, and the newest RE is on 18.3 — so the write ramdisk should
   most likely be 18.3-based, but today's `SSHRDBooter`/`SSHRDRamdiskBuilder` default
   to **17.5**. This mismatch must be resolved first or the RE addresses are wrong.
3. **Transport shape mismatch.** `writeRawBlob` pipes `base64 -d | <sinkCommand>`
   (sink reads a blob on stdin). But the real candidate tools take a **file + verb**
   (`syscfg_write info`, `syscfgset writeunlock <blob> --i-understand`) and some need
   a **kext loaded first**. The transport must grow a small "staged file + run tool"
   mode, not just a stdin pipe.
4. **SysCfg storage model not fully pinned on NAND.** It's wear-leveled / firmware-scanned
   (`Util_Find_SysCfg`, "Fast Copy B"), **not a fixed offset** (`homepod-nand-map.md`).
   So a raw `dd` write is out; the write must go through an Apple code path that
   understands the container (SetLocker, or the Diags writable kext, or `setProperties`
   routed to stage/commit).
5. **The effaceable `SetLocker` unknowns** (from `SYSCFG_WRITE_FINDINGS.md`): the exact
   SysCfg **locker type_id/tag**, its **locker class** (private/protected/normal →
   decides whether the `SecureRoot` patch is enough), and whether the UC opens at all
   from the ramdisk. All resolvable **read-only** on-device.
6. **Dangerous default boot-args on a non-destructive path.** `GasterRamdiskBooter`'s
   default `bootArgs` include `nand-enable-reformat=1 -restore` even for SysCfg **read**.
   For a read/de-risk boot these should be dropped (the `diags_boot.sh` DIAGS path keeps
   them because it's a restore-class boot; the read path shouldn't). Audit this before
   any hardware run.
7. **No automated post-write activation check.** Success is currently "bytes read back
   identical." That's necessary but the real acceptance test is "pod activates after a
   normal restore." No automation ties those together yet.

---

## 3. Proposed solution architecture

Keep the existing, good structure (booter → transport → job with read-back verify).
Add a **pluggable WriteSink** behind the transport so the three candidate mechanisms
can be swapped without touching orchestration or UI.

```
SysCfgController.restore
  └─ booter.boot()  ──────────────► BootedPod {transport, shell}
        └─ transport.writeRawBlob(blob)
              └─ WriteSink.commit(blob, via: shell)     ← NEW abstraction
                   ├─ EffaceableLockerSink  (primary:  SetLocker sel 6)
                   ├─ DiagsKextSink         (fallback: kextload + syscfg_write)
                   └─ (KernelPatchSink)     (last resort: unstub slot 44 — 18.3-invalid, keep shelved)
        └─ transport.readRawBlob() → byte-compare (already built)
```

Design rules (carry the existing safety ethos):
- Raw-bytes-verbatim write only; never re-serialize from parsed fields (already true).
- A sink reports `isValidated` just like `hasValidatedSink` today; the job refuses to
  write through an unvalidated sink. Replace the single `sinkCommand` string with a
  `WriteSink` enum so "validated" is a property of a real mechanism, not a magic string.
- Every sink is preceded by a mandatory **GetLocker/read probe** and a **same-bytes
  round-trip gate** on the specific pod before any donor/new-chip write.

---

## 4. Step-by-step implementation plan

### Phase 0 — Pin the firmware (blocking, do first)
- Decide the write ramdisk firmware. Recommend **18.3** to match the newest RE
  (`SYSCFG_WRITE_FINDINGS.md`) and the shipped restore IPSW. Update `SSHRDBooter`/
  `SSHRDRamdiskBuilder` defaults (currently 17.5) accordingly, or explicitly document
  why a different build is used for the write boot.
- Re-confirm the key RE addresses/selectors against the exact kernelcache that
  firmware ships (selector indices, `externalMethod` VA, `clientHasPrivilege` site).

### Phase 1 — Read-only on-device discovery (zero brick risk)
Run on a **known-good pod** via the existing diagnostics pull + a small extension:
1. Confirm the `AppleEffaceableStorage` user client **opens** from the ramdisk.
2. `getCapacity (0)` + `isFormatted (3)` sanity.
3. `GetLocker (5)` across candidate `type_id`s; find the tag whose bytes **equal the
   known 131072-byte `gfCS` blob**. Record its **locker class** from the `IOReturn`
   (success = readable/normal; `0xe00002xx` = protected/private + current trust state).
4. In parallel, capture whether `AppleDiagnosticDataAccess` (RW, non-ReadOnly) can be
   made to match, and whether a **Diags kernelcache** can `kextload` the writable kext
   (`diags_boot.sh` path) — this decides the fallback's viability.

Deliverable: the SysCfg `type_id`, its class, and which of the two primary sinks is
reachable. This is the single fact-finding step that unblocks everything.

### Phase 2 — Build the primary sink (EffaceableLockerSink)
- Write the tiny arm64 IOKit tool (the missing `tools/syscfg_write` / `syscfgset`):
  open `AppleEffaceableStorage` UC, `IOConnectCallMethod` for `GetLocker`/`SetLocker`
  with the pinned selector/arg shape (scalar 4CC `type_id` + struct I/O buffer).
  Build against the tvOS donor SDK, resolve IOKit via `dlsym` (per `syscfg-write-re.md`
  tooling note).
- If the locker is **protected**, add the one-instruction `clientHasPrivilege("SecureRoot")
  → true` patch to the boot kernelcache (the ramdisk kc is already patched, so this is
  incremental). If **private**, fall back to Phase 3.
- Extend `SSHRamdiskTransport` with a "stage file + run verb" mode (scp/base64 the blob
  to a tmpfs on the pod, run `syscfg_write write /tmp/blob`), and model the sink as a
  `WriteSink` case whose `isValidated` is true once Phase 4 passes.

### Phase 3 — Build the fallback sink (DiagsKextSink)
- Finish the `diags_boot.sh` DIAGS ramdisk: the patched Diags kernelcache, the writable
  `AppleDiagnosticDataAccess.kext`, `kextutil`, and the on-pod `syscfg_write`. This is
  the mechanism the Apple Wiki blesses, so it's the most likely to "just work" even if
  the effaceable locker is private.
- Same transport "stage + run" interface, different boot image. The app's
  `syscfgBootMode` already models multiple boot modes — add a "diags" mode.

### Phase 4 — Validation gate (mandatory before any real repair)
1. **Same-bytes round-trip** on a known-good pod: read own SysCfg → write the *same*
   bytes back → reboot → re-read → assert byte-identical **and** serial unchanged.
   (`SysCfgJob` already does read-back compare; add the reboot-and-reread leg.)
2. Only after a clean same-bytes round-trip, flip that sink's `isValidated = true`.
3. **End-to-end acceptance:** on a NAND-swapped unit, write the saved donor blob →
   run a normal 18.3 restore → confirm the pod **activates** and reports the correct
   serial. Wire this as the real success criterion, not just byte-compare.

### Phase 5 — Productize
- Keep the write behind the existing "Experimental" banner until N successful repairs.
- Always save the original 128 KB blob before any write (store per-ECID).
- Surface the locker class / chosen sink in the diagnostics bundle for support.

---

## 5. Risk assessment & mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| Bricking a repair unit by writing a bad/partial SysCfg | High | Already strong: raw-verbatim write, signature + essential-tag validation, read-back byte-compare, refuse-on-mismatch. Add reboot-and-reread. Keep every original blob. |
| Flashing the **17.5 kernelcache patch** that 18.3 RE proved unsafe (type confusion) | High | `SYSCFG_WRITE_FINDINGS.md` already says do-not-flash; keep `kc-syscfg-patch` shelved and out of any shipping path. Do not resurrect without a fresh RE on the pinned firmware. |
| RE addresses/selectors wrong because firmware isn't pinned | High | Phase 0 gate: pin firmware, re-verify every VA/selector against that exact kc before building sinks. |
| `SetLocker` hypothesis wrong (SysCfg not actually an effaceable locker) | Medium | Phase 1 read-only `GetLocker` probe confirms/denies before any write. If denied, DiagsKextSink (Apple-blessed) is the fallback. |
| Destructive boot-args on a read/de-risk boot (`-restore`, `nand-enable-reformat=1`) | Medium | Audit `GasterRamdiskBooter` defaults; strip restore/reformat args from the read path. |
| Transport shape mismatch (stdin pipe vs file+verb+kext) silently "succeeds" | Medium | Model sinks explicitly; `isValidated` only after Phase 4 round-trip; never trust exit code alone. |
| SysCfg is wear-leveled, so a direct region write corrupts the container | Medium | Never `dd`. Only write through SetLocker / Diags kext / stage+commit — all container-aware. |
| Activation still fails despite correct SysCfg (other per-unit data, e.g. baseband/SEP) | Low–Med | Phase 4 end-to-end activation test catches this early; HomePod has no cellular/baseband, reducing surface. |

---

## 6. Alternative approaches if the primary plan blocks

1. **Diags writable-kext (`diags_boot.sh`) as primary instead of fallback.** It is the
   canonical, wiki-documented SysCfg write route ("modify and reflash using Diags") and
   sidesteps the effaceable-locker uncertainty entirely. The cost is sourcing/patching
   a Diags kernelcache + the writable kext for b238/A8.
2. **Restore-time provisioning.** Let a real/patched restore write SysCfg as part of the
   normal flow (how Apple's factory does it), rather than a standalone tool. Heaviest,
   but closest to Apple's own mechanism and most robust against activation surprises.
3. **Minimal, *correct* kernel patch on the pinned firmware.** If both user-space sinks
   are closed, patch the ReadOnly diagnostics node's slot-44 write stub to route into
   the (still-present) stage/commit region machinery — but only after fresh RE on the
   pinned kc proves the data-injection path exists there (the 18.3 analysis says it
   doesn't on 18.3, so this would require a different build). High effort, brick risk.
4. **Hardware NAND programmer** (the thing the whole project avoids) as a last-resort
   bench fallback for units where the software path fails — carve serial/MACs from the
   dump with Reviv (`gfCS`) and program the new chip directly. Keeps a repair unblockable
   even if the free route stalls. ([Reviv](https://github.com/waynebonc/Reviv))
5. **Community collaboration.** `SYSCFG_WRITE_FINDINGS.md` and the Apple Wiki both note
   nobody has published a HomePod SysCfg-write; the MagicCFG author explicitly invites
   adding Diags profiles. Contributing the b238 profile / comparing notes with
   MagicCFG/PurpleEditor maintainers could shortcut the selector/locker-class discovery.

---

## 7. Immediate next actions (concrete)

1. **Pin the write firmware** (recommend 18.3) and reconcile the 17.5 defaults in
   `SSHRDBooter`/`SSHRDRamdiskBuilder`. *(Phase 0, blocking.)*
2. **Run the read-only Phase 1 probe on a known-good pod**: extend the existing
   diagnostics pull to open `AppleEffaceableStorage` and `GetLocker`-scan for the
   131072-byte `gfCS` blob → learn the SysCfg `type_id` + class. *(Zero risk.)*
3. **Strip `-restore`/`nand-enable-reformat=1` from the read-path boot-args.** *(Safety.)*
4. Based on (2), build **EffaceableLockerSink** (primary) or **DiagsKextSink** (fallback)
   and wire a `WriteSink` abstraction in place of the `sinkCommand` string.
5. Gate it behind the **same-bytes round-trip + reboot-reread**, then a **real NAND-swap
   activation test**, before flipping `isValidated`.

---

## Appendix: key files

- `SYSCFG_WRITE_FINDINGS.md` — **authoritative, newest** (18.3). Effaceable `SetLocker`
  plan + why the kernelcache patch is unsafe. Start here.
- `HomePodRestoreApp/docs/syscfg-write-re.md` — 17.5 investigation; its final "WRITE
  PATH SOLVED" is **superseded** by the above. Useful RE trail, do not flash its patch.
- `HomePodRestoreApp/docs/homepod-nand-map.md` — NAND layout; read path confirmed;
  SysCfg is wear-leveled (no fixed offset).
- `SSHRD_Script/diags_boot.sh` — the third (Diags writable-kext) write route; strong
  fallback; its `tools/syscfg_write` is referenced but not staged.
- `Sources/HomePodRestoreCore/SysCfgRamdiskTransport.swift` — read (done) + gated write
  (`hasValidatedSink`), write-facility probe. The sink plugs in here.
- `Sources/HomePodRestoreCore/SysCfg.swift` — parser (display/sanity only) + `SysCfgJob`
  (validate → write → read-back verify). Raw bytes retained verbatim.
- `Sources/HomePodRestoreCore/SSHRDBooter.swift` / `SysCfgSession.swift` — booters
  (PreBooted works today; in-app SSHRD boots the proven chain) + diagnostics controller.
