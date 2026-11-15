import Foundation

// MARK: - WriteSink
//
// The mechanism used to COMMIT a SysCfg blob to a HomePod's NAND.
//
// Reading SysCfg is solved (ioreg → AppleDiagnosticDataSysCfg). Writing is the
// dangerous, still-being-proven half, and there is more than one candidate
// on-device write path. Rather than bake a single `sinkCommand: String` into the
// transport, we model each write path as a `WriteSink`: a self-describing object
// that knows how to (a) PROBE the pod read-only to discover whether its path is
// present/usable, and (b) COMMIT bytes once validated.
//
// Why this shape:
//   • The transport should not know which silicon primitive is in play — it just
//     stages a file and asks the sink to commit. That keeps the one truly
//     dangerous operation behind a single, auditable `isValidated` gate.
//   • Each sink carries its own validation state (has it ever passed a same-bytes
//     round-trip on real hardware?). A write is only ever attempted through a
//     sink that says it is validated, and the transport double-checks that gate.
//   • Probes are strictly read-only, so discovery can run freely on a repair unit
//     without any brick risk — exactly the "de-risk read" posture the rest of the
//     app already takes.
//
// Authoritative background: SYSCFG_WRITE_FINDINGS.md (audioOS 18.3 / 22K557 RE).
// The setProperties/stage/commit cave documented there is SHELVED as unsafe.
//
// UPDATE from a real pod's registry: the effaceable store is ~960 bytes
// (Capacity=960, one 4096-byte unit holding four 1024-byte copies), so it cannot
// hold the 128 KB SysCfg. SysCfg is served by AppleDiagnosticDataAccessReadOnly
// on top of AppleNANDConfigAccess, a separate NAND config region. The write path
// to pursue is therefore the DIAGS kernelcache, whose writable
// AppleDiagnosticDataAccess kext replaces the read-only one — see DiagsKextSink
// and SSHRD_Script/diags_boot.sh. The effaceable sink is kept for locker
// discovery (keys / nonces) but is no longer the preferred SysCfg path.

// MARK: Sink taxonomy

/// The mechanism used to commit SysCfg bytes to NAND.
/// Each case represents a different on-device write path.
public enum WriteSinkType: String, Codable, CaseIterable, Sendable {
    /// AppleEffaceableStorageUserClient SetLocker (selector 6).
    /// Container-safe, but the store is only ~960 bytes on a real pod — too
    /// small for the 128 KB SysCfg. Kept for locker discovery.
    case effaceableLocker

    /// DIAGS kernelcache with the writable AppleDiagnosticDataAccess kext —
    /// Apple's canonical SysCfg write mechanism. Booted by diags_boot.sh (or the
    /// app's DIAGS boot mode); the ramdisk carries `/diags/syscfg_write`.
    case diagsKext

    /// Reserved: kernelcache vtable patch (SHELVED — unsafe on 18.3)
    /// case kernelPatch

    /// Human-facing short name.
    public var title: String {
        switch self {
        case .effaceableLocker: return "Effaceable locker (SetLocker)"
        case .diagsKext:        return "DIAGS kernelcache (AppleDiagnosticDataAccess)"
        }
    }

    /// One-line explanation of the trade-offs, for logs / UI.
    public var blurb: String {
        switch self {
        case .effaceableLocker:
            return "Container-safe SetLocker on AppleEffaceableStorage. On a real pod the store is only ~960 bytes, so it can't hold the 128 KB SysCfg — useful for locker discovery, not the SysCfg write."
        case .diagsKext:
            return "Apple's own SysCfg write path: a DIAGS kernelcache with the writable AppleDiagnosticDataAccess kext, driven by /diags/syscfg_write on the DIAGS ramdisk. Needs the DIAGS boot and a proven round-trip."
        }
    }

    /// Lower is tried first. The DIAGS kext is the preferred SysCfg path: the
    /// effaceable store is too small for the blob (see the note at the top).
    public var preferenceRank: Int {
        switch self {
        case .diagsKext:        return 0
        case .effaceableLocker: return 1
        }
    }
}

// MARK: - AppleEffaceableStorageUserClient selector map
//
// Straight from the 18.3 RE (SYSCFG_WRITE_FINDINGS.md "RE-complete" table). These
// are the external-method indices on the user client; the probe/commit tooling
// (`syscfg-probe`) takes a selector by number, so pinning them here keeps the
// Swift side and the on-device binary in lockstep.

/// External-method selectors on `AppleEffaceableStorageUserClient` (12-entry
/// jump table). Gates noted where relevant; see `SYSCFG_WRITE_FINDINGS.md`.
public enum EffaceableSelector: Int, Sendable, CaseIterable {
    case getCapacity     = 0   // scalarOut(1), no gate
    case getBytes        = 1   // PE_i_can_has_debugger
    case setBytes        = 2   // PE_i_can_has_debugger
    case isFormatted     = 3   // scalarOut(1), no gate
    case format          = 4   // SecureRoot
    case getLocker       = 5   // scalarIn=type_id → structOut; locker class (read) + trust
    case setLocker       = 6   // scalarIn=type_id, structIn=buf; locker class (write) + trust
    case effaceLocker    = 7   // scalarIn=type_id ('****' wildcard needs trust)
    case lockerSpace     = 8   // scalarIn=type_id → scalarOut(1)
    case wipe            = 9   // SecureRoot
    case generateNonce   = 10  // structOut(0x14)
    case setLockerWithID = 11  // PE_i_can_has_debugger
}

// MARK: - FourCC helpers
//
// Effaceable lockers are addressed by a 4-character type_id. On-flash the FourCC
// is stored byte-reversed (little-endian), which is why the SysCfg container
// signature "SCfg" appears as "gfCS" in a dump. We carry both spellings so the
// probe can match whichever the storage engine reports.

public enum FourCC {
    /// Pack a 4-char ASCII string into a big-endian UInt32 (A→high byte).
    public static func value(_ s: String) -> UInt32? {
        let b = Array(s.utf8)
        guard b.count == 4 else { return nil }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    /// Render a UInt32 back to its 4-char string (non-printable bytes → '.').
    public static func string(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                     UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        let printable = bytes.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." }
        return String(printable)
    }

    /// The byte-reversed spelling of a FourCC value (little-endian on-flash form).
    public static func reversed(_ v: UInt32) -> UInt32 {
        let bytes = [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                     UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
             | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }
}

// MARK: - Probe result

/// The read-only discovery result for a write path. Everything here is learned
/// without touching NAND, so a probe can run on any pod with zero risk.
public struct ProbeResult: Sendable, Codable, Equatable {
    /// The locker's protection class, which decides whether an untrusted
    /// (non-SecureRoot) ramdisk boot may write it. See the storage-engine
    /// locker-class model in SYSCFG_WRITE_FINDINGS.md.
    public enum LockerClass: String, Sendable, Codable {
        /// Any external userspace caller may read/write. No patch needed.
        case normal
        /// Trusted (SecureRoot) callers only — needs the one-instruction
        /// `clientHasPrivilege` force-true patch on an untrusted boot.
        case protected
        /// Driver-only; external userspace is blocked even when trusted.
        /// Would force a fall back to raw setBytes (kernel-debug) or the DIAGS kext.
        case `private`
        /// Not yet determined on this pod.
        case unknown
    }

    /// The sink this probe is about.
    public var sink: WriteSinkType
    /// Did the `AppleEffaceableStorage` IOService node show up at all?
    public var nodePresent: Bool
    /// Is its user client matchable / openable (not entitlement-walled shut)?
    public var userClientOpenable: Bool
    /// The type_id whose locker bytes matched the expected SysCfg blob, if found.
    public var lockerTypeID: UInt32?
    /// Human spelling of `lockerTypeID` (e.g. "SCfg").
    public var lockerFourCC: String?
    /// The locker's protection class.
    public var lockerClass: LockerClass
    /// Size in bytes of the locker's payload, when a GetLocker succeeded.
    public var lockerSize: Int?
    /// SecureRoot trust state of this boot, when the probe could determine it.
    /// `false` means a `clientHasPrivilege` patch is needed for a protected locker.
    public var trusted: Bool?
    /// True when a candidate locker's bytes matched the pod's known SysCfg blob
    /// (size and/or signature) — the strongest confirmation the path is right.
    public var matchedExpectedBlob: Bool
    /// Raw probe tool / ioreg text, retained for the diagnostics log.
    public var raw: String
    /// Human-readable notes (candidate type_ids tried, gate hints, etc.).
    public var notes: [String]

    public init(sink: WriteSinkType,
                nodePresent: Bool = false,
                userClientOpenable: Bool = false,
                lockerTypeID: UInt32? = nil,
                lockerFourCC: String? = nil,
                lockerClass: LockerClass = .unknown,
                lockerSize: Int? = nil,
                trusted: Bool? = nil,
                matchedExpectedBlob: Bool = false,
                raw: String = "",
                notes: [String] = []) {
        self.sink = sink
        self.nodePresent = nodePresent
        self.userClientOpenable = userClientOpenable
        self.lockerTypeID = lockerTypeID
        self.lockerFourCC = lockerFourCC
        self.lockerClass = lockerClass
        self.lockerSize = lockerSize
        self.trusted = trusted
        self.matchedExpectedBlob = matchedExpectedBlob
        self.raw = raw
        self.notes = notes
    }

    /// Does the probe show enough to even attempt a (gated) same-bytes round-trip?
    /// The locker must be present, its user client openable, and a matching
    /// type_id found. Writeability of a `protected` locker still depends on trust.
    public var looksWriteReachable: Bool {
        nodePresent && userClientOpenable && lockerTypeID != nil && lockerClass != .private
    }
}

// MARK: - Per-sink validation state (persistable)

/// Records how far a sink has been proven on real hardware. Persisted per-sink so
/// a validated path survives app restarts and a tech never has to re-prove it on
/// every launch. The staircase mirrors the "safest first" plan in the findings
/// doc: open UC → read locker → same-bytes round-trip → end-to-end activation.
public struct WriteSinkValidation: Sendable, Codable, Equatable {
    /// The `AppleEffaceableStorage` user client opened successfully.
    public var userClientOpened: Bool
    /// GetLocker returned the pod's own SysCfg blob (read path through the sink).
    public var lockerRead: Bool
    /// Same-bytes round-trip verified: wrote the pod's OWN bytes back, rebooted,
    /// re-read, and got byte-identical content. THIS is the gate that makes a
    /// sink safe to use for a real new-chip write.
    public var roundTripVerified: Bool
    /// A pod activated normally after a real (donor→blank) write through this sink.
    public var endToEndActivated: Bool
    /// When the round-trip was last verified.
    public var lastValidatedAt: Date?
    /// The audioOS build the validation was done against (e.g. "22K557"). A build
    /// change should force re-validation — the RE is build-specific.
    public var lastValidatedBuild: String?

    public init(userClientOpened: Bool = false,
                lockerRead: Bool = false,
                roundTripVerified: Bool = false,
                endToEndActivated: Bool = false,
                lastValidatedAt: Date? = nil,
                lastValidatedBuild: String? = nil) {
        self.userClientOpened = userClientOpened
        self.lockerRead = lockerRead
        self.roundTripVerified = roundTripVerified
        self.endToEndActivated = endToEndActivated
        self.lastValidatedAt = lastValidatedAt
        self.lastValidatedBuild = lastValidatedBuild
    }

    /// A sink is write-safe once it has opened the UC, read the locker, and passed
    /// a same-bytes round-trip. `endToEndActivated` is the extra confidence signal,
    /// not a precondition for an owner's-own-bytes restore.
    public var isWriteSafe: Bool { userClientOpened && lockerRead && roundTripVerified }

    /// Fold a fresh probe into the read-side validation flags (non-destructive).
    public mutating func absorb(_ probe: ProbeResult) {
        if probe.userClientOpenable { userClientOpened = true }
        if probe.matchedExpectedBlob || probe.lockerSize != nil { lockerRead = true }
    }
}

// MARK: - WriteSink protocol

/// A single on-device SysCfg write path. Conformers are value types that carry
/// their own settings + validation state, so they are cheap to pass across the
/// `Sendable` boundary the transport lives behind.
public protocol WriteSink: Sendable {
    /// Which mechanism this is.
    var type: WriteSinkType { get }

    /// Has this sink passed a same-bytes round-trip on real hardware? The transport
    /// refuses to write through a sink that answers `false`. Never a guess — it is
    /// backed by persisted `WriteSinkValidation`.
    var isValidated: Bool { get }

    /// READ-ONLY discovery. Opens the relevant node, tries to locate the SysCfg
    /// locker, and reports what it found. Zero write risk — safe on any pod.
    func probe(via shell: RamdiskShell) async throws -> ProbeResult

    /// Commit `blob` to NAND through this path. MUST only be reached for a
    /// validated sink; conformers also assert their own preconditions (a confirmed
    /// type_id, a staged file) and throw rather than guess.
    func commit(blob: Data, via shell: RamdiskShell) async throws
}

// MARK: - RamdiskShell staging helpers
//
// "Stage a file, then run a tool" is the real on-device write shape (unlike the
// legacy `base64 | sink` stdin pipe). SysCfg is ~128 KB, whose base64 (~170 KB)
// can blow past a single command line's ARG_MAX, so staging is CHUNKED: append
// base64 fragments to a temp file, then decode it in one step. Implemented on
// `RamdiskShell` so every sink (and the transport) shares one correct copy.

@inline(__always)
func hprShellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public extension RamdiskShell {
    /// Write `data` to `remotePath` on the pod in bounded commands (ARG_MAX-safe),
    /// then verify the staged byte count. Overwrites any existing file.
    ///
    /// The bytes go as `printf` octal escapes (`DiagCommands.fileWriteCommands`),
    /// decoded by the pod's shell itself. This used to append base64 fragments
    /// and run `base64 -d`, but the ramdisk has no `base64` (and no `tr`), so
    /// that could never succeed there. `chunkSize` is the most characters sent
    /// per command.
    func stage(_ data: Data, at remotePath: String, chunkSize: Int = DiagCommands.transferBudget) async throws {
        let q = hprShellQuote
        for command in DiagCommands.fileWriteCommands(quotedPath: q(remotePath), data: data, budget: chunkSize) {
            _ = try await run(command)
        }
        // Verify the staged size matches what we sent, so a truncated transfer is
        // caught before any tool reads the file. A size that can't be read is a
        // failure too — never proceed on an unverified file.
        guard let got = try await stagedSize(of: remotePath) else {
            throw SysCfgError.transportUnavailable("Couldn't read back the size of staged file \(remotePath); not proceeding.")
        }
        if got != data.count {
            throw SysCfgError.transportUnavailable("Staged file \(remotePath) is \(got) bytes but \(data.count) were sent — transfer was truncated; not proceeding.")
        }
    }

    /// Byte count of a staged file, or nil if it couldn't be read.
    func stagedSize(of remotePath: String) async throws -> Int? {
        let q = hprShellQuote
        // `wc` pads its count with spaces; they are dropped here rather than
        // with `tr`, which this ramdisk doesn't have. PATH is set because
        // /usr/bin is not on dropbear's default PATH.
        let out = try await run("PATH=\(DiagCommands.basePath); export PATH; wc -c < \(q(remotePath))")
        let line = out.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        return Int(line)
    }
}

// MARK: - Effaceable locker sink (PRIMARY)

/// Writes SysCfg via `AppleEffaceableStorageUserClient::SetLocker` (selector 6).
///
/// This is the container-safe path: SetLocker does the storage engine's own
/// generation/checksum/commit, so a correct write can't half-corrupt the locker
/// the way a raw setBytes could. The only gate likely to matter is the SecureRoot
/// trust check for a *protected* locker, which is a one-instruction kernel patch
/// we already have room for in the boot chain.
///
/// The actual IOKit calls are made by a tiny on-device arm64 helper (`syscfg-probe`;
/// interface specced in docs/writesink-architecture.md). This Swift type stages
/// the blob, drives that helper, and tracks validation — it contains no IOKit
/// itself, so it stays Foundation-only and testable off-device.
public struct EffaceableLockerSink: WriteSink {
    public struct Settings: Sendable, Codable, Equatable {
        /// Pod-side path to the arm64 helper that makes the IOConnectCallMethod
        /// calls. Shipped in the ramdisk overlay.
        public var toolPath: String
        /// Pod-side path to the read-only ioreg enumeration script.
        public var probeScriptPath: String
        /// Where the blob is staged before SetLocker reads it.
        public var stagePath: String
        /// The confirmed SysCfg locker type_id once discovered on-device. Writes
        /// are refused until this is set — we never SetLocker a guessed tag.
        public var confirmedTypeID: UInt32?
        /// Candidate type_ids to try during probe, in order. Both the forward and
        /// byte-reversed spellings of each FourCC are attempted automatically.
        public var candidateFourCCs: [String]
        /// Expected SysCfg blob size, used to recognise the right locker during
        /// probe (the 1st-gen HomePod dump is 128 KiB).
        public var expectedBlobSize: Int
        /// Persisted validation state for this sink.
        public var validation: WriteSinkValidation

        public init(toolPath: String = "/usr/local/bin/syscfg-probe",
                    probeScriptPath: String = "/usr/local/bin/hpdiag-getlocker",
                    stagePath: String = "/tmp/syscfg.bin",
                    confirmedTypeID: UInt32? = nil,
                    candidateFourCCs: [String] = ["SCfg", "SyCf", "ScFg", "Cnfg", "nvSC"],
                    expectedBlobSize: Int = 131072,
                    validation: WriteSinkValidation = .init()) {
            self.toolPath = toolPath
            self.probeScriptPath = probeScriptPath
            self.stagePath = stagePath
            self.confirmedTypeID = confirmedTypeID
            self.candidateFourCCs = candidateFourCCs
            self.expectedBlobSize = expectedBlobSize
            self.validation = validation
        }

        /// Candidate type_ids as UInt32, forward spelling then reversed, de-duped.
        public var candidateTypeIDs: [UInt32] {
            var out: [UInt32] = []
            for s in candidateFourCCs {
                guard let v = FourCC.value(s) else { continue }
                if !out.contains(v) { out.append(v) }
                let r = FourCC.reversed(v)
                if !out.contains(r) { out.append(r) }
            }
            return out
        }
    }

    public var settings: Settings
    public init(settings: Settings = .init()) { self.settings = settings }

    public var type: WriteSinkType { .effaceableLocker }

    /// Validated only when a same-bytes round-trip has passed AND we know which
    /// type_id to write. Both conditions are required — a round-trip proven on one
    /// pod still needs the confirmed tag to target the write.
    public var isValidated: Bool {
        settings.validation.isWriteSafe && settings.confirmedTypeID != nil
    }

    public func probe(via shell: RamdiskShell) async throws -> ProbeResult {
        var result = ProbeResult(sink: .effaceableLocker)
        var raw = ""

        // 1) Read-only ioreg enumeration via the overlay script: is the node there
        //    and is the user client matchable? This runs with no IOKit of its own.
        let scriptCmd = "PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin "
            + hprShellQuote(settings.probeScriptPath)
        if let scriptOut = try? await shell.run(scriptCmd) {
            raw += scriptOut
            if let j = Self.extractJSON(scriptOut, begin: "HPDIAG_GETLOCKER_BEGIN", end: "HPDIAG_GETLOCKER_END") {
                result.nodePresent = (j["effaceableStoragePresent"] as? Bool) ?? false
                result.userClientOpenable = (j["userClientMatchable"] as? Bool) ?? false
                if let notes = j["notes"] as? [String] { result.notes += notes }
            } else {
                result.notes.append("hpdiag-getlocker produced no JSON block — is it installed in the overlay?")
            }
        } else {
            result.notes.append("Couldn't run \(settings.probeScriptPath) on the pod.")
        }

        // 2) If the arm64 helper is present, let it actually call GetLocker across
        //    candidate type_ids and report the one holding the SysCfg blob. Still
        //    read-only (GetLocker, selector 5). Absent helper → probe is limited to
        //    the ioreg enumeration above, which is fine and still safe.
        let ids = settings.candidateTypeIDs.map(String.init).joined(separator: ",")
        let getCmd = "PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin "
            + "test -x \(hprShellQuote(settings.toolPath)) && "
            + hprShellQuote(settings.toolPath)
            + " get-locker --json --candidates \(ids) --expect-size \(settings.expectedBlobSize)"
        if let toolOut = try? await shell.run(getCmd), !toolOut.isEmpty {
            raw += "\n" + toolOut
            if let j = Self.extractJSON(toolOut, begin: "SYSCFG_PROBE_BEGIN", end: "SYSCFG_PROBE_END") {
                if let opened = j["userClientOpened"] as? Bool, opened { result.userClientOpenable = true }
                if let tid = (j["lockerTypeID"] as? NSNumber)?.uint32Value ?? Self.uint32(j["lockerTypeID"]) {
                    result.lockerTypeID = tid
                    result.lockerFourCC = FourCC.string(tid)
                }
                if let size = Self.int(j["lockerSize"]) { result.lockerSize = size }
                if let cls = j["lockerClass"] as? String,
                   let parsed = ProbeResult.LockerClass(rawValue: cls) { result.lockerClass = parsed }
                if let trusted = j["trusted"] as? Bool { result.trusted = trusted }
                if let matched = j["matchedExpectedBlob"] as? Bool { result.matchedExpectedBlob = matched }
                if let notes = j["notes"] as? [String] { result.notes += notes }
            }
        } else {
            result.notes.append("syscfg-probe not present/executable at \(settings.toolPath) — ran ioreg enumeration only (still read-only).")
        }

        result.raw = raw
        return result
    }

    public func commit(blob: Data, via shell: RamdiskShell) async throws {
        // Defense in depth: the transport also gates on isValidated, but never
        // write through an unvalidated sink even if called directly.
        guard isValidated else {
            throw SysCfgError.transportUnavailable("Effaceable-locker sink isn't validated yet (needs a same-bytes round-trip and a confirmed SysCfg type_id). Run the GetLocker probe and the round-trip first.")
        }
        guard let typeID = settings.confirmedTypeID else {
            throw SysCfgError.transportUnavailable("No confirmed SysCfg locker type_id — refusing to SetLocker a guessed tag.")
        }
        // Stage the exact bytes, then SetLocker (selector 6) from the staged file.
        try await shell.stage(blob, at: settings.stagePath)
        let cmd = "PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin "
            + hprShellQuote(settings.toolPath)
            + " set-locker --json --type-id \(typeID) --in \(hprShellQuote(settings.stagePath))"
        let out = try await shell.run(cmd)
        // The helper prints a JSON result; treat a missing/!ok as failure.
        if let j = Self.extractJSON(out, begin: "SYSCFG_PROBE_BEGIN", end: "SYSCFG_PROBE_END"),
           let ok = j["ok"] as? Bool, ok {
            return
        }
        throw SysCfgError.transportUnavailable("SetLocker didn't confirm success. Tool output:\n\(out)")
    }

    // MARK: JSON extraction (sentinel-wrapped, survives SSH banners)

    static func extractJSON(_ text: String, begin: String, end: String) -> [String: Any]? {
        guard let a = text.range(of: begin), let b = text.range(of: end),
              a.upperBound <= b.lowerBound else { return nil }
        let inner = String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = inner.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func uint32(_ any: Any?) -> UInt32? {
        if let n = any as? NSNumber { return n.uint32Value }
        if let s = any as? String { return UInt32(s) ?? (s.hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16) : nil) }
        return nil
    }
    static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - DIAGS kext sink

/// Writes SysCfg through a DIAGS kernelcache that carries the *writable*
/// `AppleDiagnosticDataAccess` kext — Apple's canonical SysCfg write mechanism.
///
/// How the pod gets there: `SSHRD_Script/diags_boot.sh` (or the app's DIAGS boot
/// mode, `SSHRDBooter.Config.diags`) boots a patched 11.2 DIAGS kernelcache with
/// an SSH ramdisk. The writable kext is prelinked in that kernelcache — nothing
/// is loaded at runtime — and the ramdisk carries the writer at
/// `/diags/syscfg_write`. On the ordinary SSH ramdisk only
/// `AppleDiagnosticDataAccessReadOnly` exists and this sink's probe says so.
///
/// It starts unvalidated and `commit` refuses until a same-bytes round-trip has
/// been proven AND the writer's exact command line has been confirmed
/// (`Settings.writeCommandTemplate`) — this type never guesses at how to invoke
/// a tool that writes to NAND.
public struct DiagsKextSink: WriteSink {
    /// Where the DIAGS ramdisk carries the writer (placed by diags_boot.sh).
    public static let defaultToolPath = "/diags/syscfg_write"
    /// The writable kext's class. The stock ramdisk has only the `…ReadOnly` one.
    public static let writableClass = "AppleDiagnosticDataAccess"
    public static let readOnlyClass = "AppleDiagnosticDataAccessReadOnly"
    /// Placeholder in `writeCommandTemplate` replaced by the staged blob's path.
    public static let stagedPathPlaceholder = "{in}"

    public struct Settings: Sendable, Codable, Equatable {
        /// Pod-side path of the writer on the DIAGS ramdisk.
        public var toolPath: String
        /// Where the blob is staged before the writer reads it.
        public var stagePath: String
        /// The writer's full pod-side command line, with `{in}` standing for the
        /// staged blob's path — e.g. "/diags/syscfg_write <subcommand> {in}".
        /// nil until the tool's write interface has been confirmed on hardware;
        /// `commit` refuses while it is nil.
        public var writeCommandTemplate: String?
        public var validation: WriteSinkValidation
        public init(toolPath: String = DiagsKextSink.defaultToolPath,
                    stagePath: String = "/tmp/syscfg.bin",
                    writeCommandTemplate: String? = nil,
                    validation: WriteSinkValidation = .init()) {
            self.toolPath = toolPath
            self.stagePath = stagePath
            self.writeCommandTemplate = writeCommandTemplate
            self.validation = validation
        }
    }

    public var settings: Settings
    public init(settings: Settings = .init()) { self.settings = settings }

    public var type: WriteSinkType { .diagsKext }

    /// Validated only with a proven round-trip AND a confirmed write command.
    public var isValidated: Bool {
        settings.validation.isWriteSafe && settings.writeCommandTemplate != nil
    }

    static let toolPresentMarker = "HPDIAGS_TOOL=present"
    static let toolMissingMarker = "HPDIAGS_TOOL=missing"

    /// READ-ONLY. Names-only registry queries (no property is read) plus a file
    /// test for the writer. The writer itself is NOT run here.
    func probeCommand() -> String {
        let tool = hprShellQuote(settings.toolPath)
        return RamdiskIOReg.command([
            "echo '== \(Self.writableClass) =='",
            "hpior -r -c \(Self.writableClass)",
            "echo '== \(Self.readOnlyClass) =='",
            "hpior -r -c \(Self.readOnlyClass)",
            "echo '== writer =='",
            "if [ -x \(tool) ]; then echo \(Self.toolPresentMarker); else echo \(Self.toolMissingMarker); fi",
        ].joined(separator: "; "))
    }

    /// True when `text` has a registry node whose class is exactly `name`
    /// ("<class Name," — so `AppleDiagnosticDataAccess` does not match the
    /// `AppleDiagnosticDataAccessReadOnly` node).
    static func hasNode(ofClass name: String, in text: String) -> Bool {
        text.contains("<class \(name),") || text.contains("<class \(name)>")
    }

    public func probe(via shell: RamdiskShell) async throws -> ProbeResult {
        var result = ProbeResult(sink: .diagsKext)
        let out = SSHRamdiskTransport.stripAnsi((try? await shell.run(probeCommand())) ?? "")
        result.raw = out
        let writable = Self.hasNode(ofClass: Self.writableClass, in: out)
        let readOnly = Self.hasNode(ofClass: Self.readOnlyClass, in: out)
        let toolPresent = out.contains(Self.toolPresentMarker)
        // "Present" means the WRITABLE kext — the read-only one is on every
        // ramdisk and says nothing about this path.
        result.nodePresent = writable
        if writable {
            result.notes.append("Writable \(Self.writableClass) kext present — this pod is booted from the DIAGS kernelcache.")
        } else if readOnly {
            result.notes.append("Only \(Self.readOnlyClass) is present — this is the stock SSH ramdisk kernel. Boot the DIAGS kernelcache (diags_boot.sh, or the app's DIAGS boot mode) to reach the write path.")
        } else {
            result.notes.append("No \(Self.writableClass) node found — this path needs the DIAGS kernelcache booted.")
        }
        if toolPresent {
            result.notes.append("Writer present at \(settings.toolPath).")
        } else {
            result.notes.append("No writer at \(settings.toolPath) — rebuild the DIAGS ramdisk (diags_boot.sh images) so it includes syscfg_write.")
        }
        if writable && toolPresent {
            result.notes.append("Kext and writer are both present. Writability is only proven by a same-bytes round-trip; nothing has been written.")
        }
        return result
    }

    public func commit(blob: Data, via shell: RamdiskShell) async throws {
        guard settings.validation.isWriteSafe else {
            throw SysCfgError.transportUnavailable("DIAGS-kext sink isn't validated. This path requires the DIAGS kernelcache (writable AppleDiagnosticDataAccess) and a proven same-bytes round-trip before any live write.")
        }
        guard let template = settings.writeCommandTemplate,
              template.contains(Self.stagedPathPlaceholder) else {
            throw SysCfgError.transportUnavailable("The DIAGS writer's command line hasn't been confirmed (no write command set for \(settings.toolPath)) — refusing to guess how to invoke a tool that writes to NAND.")
        }
        // Make sure this really is a DIAGS boot before staging anything.
        let probed = try await probe(via: shell)
        guard probed.nodePresent else {
            throw SysCfgError.transportUnavailable("The writable AppleDiagnosticDataAccess kext isn't present — this pod isn't booted from the DIAGS kernelcache. Nothing was written.")
        }
        try await shell.stage(blob, at: settings.stagePath)
        let cmd = "PATH=" + RamdiskIOReg.searchPath + "; export PATH; "
            + template.replacingOccurrences(of: Self.stagedPathPlaceholder, with: hprShellQuote(settings.stagePath))
        _ = try await shell.run(cmd)
    }
}

// MARK: - Validation registry (persistence)

/// A persistable map of per-sink validation state. Serialized to JSON so a
/// validated write path is remembered across launches. Stored by the app layer
/// (e.g. under Application Support); kept Foundation-only here so Core owns the
/// shape and the load/save, and the app just points it at a URL.
public struct WriteSinkRegistry: Sendable, Codable, Equatable {
    /// Validation state keyed by sink type.
    public var validations: [WriteSinkType: WriteSinkValidation]
    /// The build these validations were recorded against; a mismatch should
    /// prompt re-validation since the RE is build-specific.
    public var build: String?

    public init(validations: [WriteSinkType: WriteSinkValidation] = [:], build: String? = nil) {
        self.validations = validations
        self.build = build
    }

    public func validation(for type: WriteSinkType) -> WriteSinkValidation {
        validations[type] ?? .init()
    }

    public mutating func set(_ v: WriteSinkValidation, for type: WriteSinkType) {
        validations[type] = v
    }

    /// Load from disk, returning an empty registry if the file is absent/corrupt.
    public static func load(from url: URL) -> WriteSinkRegistry {
        guard let data = try? Data(contentsOf: url),
              let reg = try? JSONDecoder().decode(WriteSinkRegistry.self, from: data) else {
            return WriteSinkRegistry()
        }
        return reg
    }

    /// Persist atomically.
    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
