import Foundation

// MARK: - SysCfg data model
//
// SysCfg ("System Configuration") is the small block of per-unit data that
// lives on a HomePod's NAND: serial number, Wi-Fi MAC, Bluetooth MAC, MLB
// serial, region, etc. When the NAND chip is replaced, this block is gone and
// the board won't activate until the UNIT'S OWN ORIGINAL SysCfg is written to
// the new chip. Recovering a repaired board's own identity is the entire job
// here — this is the software equivalent of what the hardware NAND programmers
// do, and it does not touch Activation Lock / Find My.
//
// Design note — why we keep the raw bytes verbatim:
// The RESTORE path writes back the exact original blob we read (or the exact
// blob a carving tool recovered). It never re-serializes from parsed fields, so
// restore correctness does NOT depend on the parser below being byte-perfect.
// The parser exists only to SHOW the human the serial/MACs and to sanity-check
// a dump (e.g. "does this look like a real SysCfg, and does the serial match
// the sticker?"). That keeps the dangerous path (writing silicon) trivially
// safe while still giving a useful read-out.

/// One tag → value entry inside a SysCfg blob. `tag` is a four-character code
/// such as "SrNm" (serial) or "WMac" (Wi-Fi MAC).
public struct SysCfgField: Sendable, Equatable {
    public let tag: String
    public let value: Data

    public init(tag: String, value: Data) {
        self.tag = tag
        self.value = value
    }

    /// Printable ASCII interpretation (serial numbers, model, region…), trimmed
    /// of NULs/whitespace. `nil` when the bytes aren't printable text.
    public var text: String? {
        let trimmed = value.prefix { $0 != 0 }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        let s = String(decoding: trimmed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Length of a MAC address. MACs are fixed-width binary, never NUL-terminated.
    public static let macLength = 6

    /// Six-byte MAC formatted as aa:bb:cc:dd:ee:ff. `nil` unless exactly 6 bytes.
    ///
    /// BUGFIX (MAC 0x00 truncation): this used to accept any 1...8 byte value,
    /// which papered over the parser cutting MACs short at the first 0x00 byte
    /// (a 3-byte "MAC" was formatted and shown as if it were real). The parser
    /// now always hands us exactly 6 raw bytes for MAC tags, so enforce the
    /// length the doc comment always promised. 0x00 bytes anywhere in the MAC
    /// (including the first octet, e.g. 00:1c:b3:…) are valid data.
    ///
    /// An all-0x00 or all-0xFF value is still rejected: that is blank/erased
    /// flash, not an address. (The old read-until-NUL code rejected both too,
    /// so this keeps the restore gate from getting any looser than it was.)
    public var macString: String? {
        guard value.count == Self.macLength else { return nil }
        guard !value.allSatisfy({ $0 == 0x00 }), !value.allSatisfy({ $0 == 0xFF }) else { return nil }
        return value.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// A parsed (best-effort) view of a SysCfg blob plus the original bytes.
public struct SysCfgData: Sendable, Equatable {
    /// The blob exactly as read. This is what the restore path writes back.
    public let rawBytes: Data
    /// Fields we could identify. Best-effort; see the parsing note above.
    public let fields: [SysCfgField]
    /// True when the blob carried a recognizable SysCfg container signature.
    public let looksValid: Bool

    public init(rawBytes: Data, fields: [SysCfgField], looksValid: Bool) {
        self.rawBytes = rawBytes
        self.fields = fields
        self.looksValid = looksValid
    }

    public func field(_ tag: String) -> SysCfgField? { fields.first { $0.tag == tag } }

    // Convenience accessors for the three fields a NAND swap must restore.
    public var serialNumber: String? { field("SrNm")?.text ?? field("Srnm")?.text }
    public var wifiMAC: String? { field("WMac")?.macString ?? field("WMAc")?.macString }
    public var bluetoothMAC: String? { field("BMac")?.macString ?? field("BMAc")?.macString }
    // BUGFIX (MLB serial never shown): "MLBN" was looked up here but was never
    // in SysCfgParser.knownTags, so the parser never extracted it and this was
    // always nil. Both tags are now in knownTags. "MLB#" is the key Apple's
    // SysCfg normally uses for the logic-board serial (same "#" style as
    // "Mod#"/"RMd#"), so fall back to it — same pattern as the SrNm/Srnm
    // fallback above. Display-only; not part of the restore gate.
    public var mlbSerial: String? { field("MLBN")?.text ?? field("MLB#")?.text }
    public var region: String? { field("Regn")?.text }
    public var model: String? { field("Mod#")?.text }

    /// Tags whose presence we care about when judging whether a dump is usable
    /// for a restore (the identity-bearing ones).
    public static let essentialTags = ["SrNm", "WMac", "BMac"]

    /// Does this dump contain the identity fields a NAND swap needs?
    public var hasEssentials: Bool {
        serialNumber != nil && wifiMAC != nil && bluetoothMAC != nil
    }

    /// The essential tags that are absent or unusable, for error messages.
    ///
    /// BUGFIX: the restore guard used to build this list from `field(tag) == nil`
    /// while `hasEssentials` judges the decoded values. Those two can disagree
    /// (tag present but value unusable, e.g. a blank MAC), which produced a
    /// "missing required fields ()" error naming nothing. Derive the list from
    /// the same accessors `hasEssentials` uses so they always agree.
    public var missingEssentialTags: [String] {
        var missing: [String] = []
        if serialNumber == nil { missing.append("SrNm") }
        if wifiMAC == nil { missing.append("WMac") }
        if bluetoothMAC == nil { missing.append("BMac") }
        return missing
    }
}

// MARK: - Parsing
//
// IMPORTANT: the exact on-flash container layout must be confirmed against the
// first real known-good dump (that's precisely the de-risk read). Until then we
// use a defensive tag scanner: find known four-char-codes, read a plausible
// length, bound it hard, and extract. Unknown-but-well-formed TLV triples are
// also captured so nothing is silently dropped. Raw bytes are always retained,
// so a mis-parse here can never corrupt a restore.

public enum SysCfgParser {
    // SysCfg format (per the Reviv carver, which is the proven reference):
    // four-char keys are stored REVERSED in the dump (little-endian FourCC), the
    // value follows the 4-byte key directly. TEXT values run until a NUL (max 50
    // bytes); BINARY values (MACs, `hex: true`) are fixed-width — exactly 6 bytes
    // — and may legitimately contain 0x00, so they are never NUL-terminated.
    // The container signature "SCfg" is therefore stored as "gfCS".

    /// (forward tag, value is raw bytes shown as hex). Matches Reviv's key set.
    ///
    /// Tags are listed here in FORWARD (human) form; `parse` reverses each one
    /// before searching, so e.g. "SrNm" is matched as "mNrS" in the dump. Do NOT
    /// pre-reverse entries in this table or they will be reversed twice.
    static let knownTags: [(tag: String, hex: Bool)] = [
        ("SrNm", false),  // serial number
        ("WMac", true),   // Wi-Fi MAC
        ("BMac", true),   // Bluetooth MAC
        ("Mod#", false),  // model number
        ("Regn", false),  // region
        ("RMd#", false),  // model
        // BUGFIX (MLB serial never shown): SysCfgData.mlbSerial looks up "MLBN",
        // but it was missing from this table, so it was never extracted and the
        // "MLB serial" UI row never appeared. Forward form here → searched as
        // "NBLM" in the dump, same convention as every other entry.
        ("MLBN", false),  // MLB (logic board) serial
        // Apple's usual SysCfg key for the MLB serial is "MLB#" (stored "#BLM").
        // Listed as well so the row shows whichever spelling a real dump uses.
        // TO CONFIRM against the first known-good dump, like the rest of this
        // layout. Display-only: neither tag is in essentialTags.
        ("MLB#", false),  // MLB serial (Apple's usual key)
    ]

    /// "SCfg" stored reversed.
    static let signatureReversed = Array("gfCS".utf8)

    public static func parse(_ data: Data) -> SysCfgData {
        let bytes = [UInt8](data)
        let valid = indexOf(signatureReversed, in: bytes, upTo: bytes.count) != nil

        var fields: [SysCfgField] = []
        for (tag, isBinary) in knownTags {
            // Keys are stored reversed; search for the reversed four-char code.
            let needle = Array(tag.utf8.reversed())
            guard let pos = indexOf(needle, in: bytes, upTo: bytes.count) else { continue }
            // Value directly follows the 4-byte key.
            var i = pos + 4

            if isBinary {
                // BUGFIX (MAC 0x00 truncation): MAC tags are fixed-width binary —
                // ALWAYS exactly 6 bytes. They used to go through the read-until-
                // NUL loop below, so a MAC containing a 0x00 octet was cut short
                // and a MAC whose FIRST octet is 0x00 (e.g. 00:1c:b3:…) produced
                // an empty value and was reported as missing — which made the
                // restore guard refuse a perfectly valid dump.
                //
                // Now: "present" means the tag exists in the blob with a full 6
                // bytes after it; the byte values themselves are not inspected
                // here. Only a blob that ends before 6 bytes are available counts
                // as missing (truncated dump).
                let end = i + SysCfgField.macLength
                guard end <= bytes.count else { continue }
                fields.append(SysCfgField(tag: tag, value: Data(bytes[i..<end])))
                continue
            }

            // Text value: read until NUL (cap 50). Unchanged.
            var value: [UInt8] = []
            while i < bytes.count, bytes[i] != 0, value.count < 50 {
                value.append(bytes[i]); i += 1
            }
            if !value.isEmpty { fields.append(SysCfgField(tag: tag, value: Data(value))) }
        }
        return SysCfgData(rawBytes: data, fields: fields, looksValid: valid)
    }

    static func indexOf(_ needle: [UInt8], in haystack: [UInt8], upTo limit: Int) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let last = min(limit, haystack.count) - needle.count
        if last < 0 { return nil }
        var i = 0
        while i <= last {
            if Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - Transport
//
// Abstracts "talk to SysCfg on a pod that's already booted into a shell-capable
// ramdisk." Two conformers: the real SSH-over-usbmux transport (hardware), and
// a fake used by tests and the de-risk dry run.

public protocol SysCfgTransport: Sendable {
    /// Read the live SysCfg blob off the booted pod. Non-destructive.
    func readRawBlob() async throws -> Data
    /// Write a recovered SysCfg blob to the pod's NAND. Destructive — gated by
    /// the caller, never called by a read-only job.
    func writeRawBlob(_ data: Data) async throws
}

public enum SysCfgError: Error, LocalizedError {
    case transportUnavailable(String)
    case emptyDump
    case notValidSysCfg
    case missingEssentials([String])
    case writeNotConfirmed

    public var errorDescription: String? {
        switch self {
        case .transportUnavailable(let why): return why
        case .emptyDump: return "The pod returned an empty SysCfg dump — the ramdisk booted but the read command produced nothing."
        case .notValidSysCfg: return "The dump doesn't look like a SysCfg block (no known signature). Not writing anything based on it."
        case .missingEssentials(let tags): return "The dump is missing required fields (\(tags.joined(separator: ", "))). It can't be used to restore identity."
        case .writeNotConfirmed: return "Restore was requested without explicit confirmation — refusing to write to NAND."
        }
    }
}

// MARK: - Fake transport (tests + dry run)

/// In-memory transport. `readRawBlob` returns a seeded blob; `writeRawBlob`
/// records what it was asked to write. Lets the whole read/verify/restore flow
/// run with no hardware, exactly like the existing fake-tool job tests.
public actor FakeSysCfgTransport: SysCfgTransport {
    private var stored: Data
    public private(set) var lastWritten: Data?

    public init(seed: Data) { self.stored = seed }

    public func readRawBlob() async throws -> Data { stored }

    public func writeRawBlob(_ data: Data) async throws {
        lastWritten = data
        stored = data
    }
}

// MARK: - SysCfgJob
//
// Orchestrates a SysCfg operation on one pod. Reuses the restore app's unlock
// coordinator (checkm8 is serialized across pods) and leaves ramdisk boot to
// the transport. Defaults to read-only.

public final class SysCfgJob: @unchecked Sendable, Identifiable {
    public enum Mode: Sendable, Equatable {
        /// Read the live SysCfg and parse it for display. Non-destructive — the
        /// de-risk step: prove the path on a known-good pod before touching a
        /// repair unit.
        case read
        /// Write a recovered blob to NAND. `confirmed` must be true.
        case restore(blob: Data, confirmed: Bool)
    }

    public enum Outcome: Sendable, Equatable {
        case running
        case read(SysCfgData)
        case restored
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let ecid: UInt64
    public let mode: Mode
    private let transport: SysCfgTransport
    private let onUpdate: @Sendable (String) -> Void

    public init(ecid: UInt64, mode: Mode, transport: SysCfgTransport,
                onUpdate: @escaping @Sendable (String) -> Void = { _ in }) {
        self.ecid = ecid
        self.mode = mode
        self.transport = transport
        self.onUpdate = onUpdate
    }

    public var ecidHex: String { String(format: "0x%016llX", ecid) }

    /// Runs the operation. Unlock is serialized via the shared coordinator so it
    /// never races a concurrent restore.
    public func run() async -> Outcome {
        // Guard the destructive path before doing anything.
        if case .restore(let blob, let confirmed) = mode {
            if !confirmed { return .failed(SysCfgError.writeNotConfirmed.localizedDescription) }
            let parsed = SysCfgParser.parse(blob)
            guard parsed.looksValid else { return .failed(SysCfgError.notValidSysCfg.localizedDescription) }
            guard parsed.hasEssentials else {
                // BUGFIX: was `essentialTags.filter { parsed.field($0) == nil }`,
                // which could come back empty while hasEssentials was false.
                let missing = parsed.missingEssentialTags
                return .failed(SysCfgError.missingEssentials(missing).localizedDescription)
            }
        }

        do {
            switch mode {
            case .read:
                onUpdate("Reading SysCfg from \(ecidHex)…")
                let blob = try await transport.readRawBlob()
                guard !blob.isEmpty else { return .failed(SysCfgError.emptyDump.localizedDescription) }
                let parsed = SysCfgParser.parse(blob)
                onUpdate("Read \(blob.count) bytes — serial \(parsed.serialNumber ?? "?"), Wi-Fi \(parsed.wifiMAC ?? "?"), BT \(parsed.bluetoothMAC ?? "?")")
                return .read(parsed)
            case .restore(let blob, _):
                onUpdate("Writing \(blob.count) bytes of recovered SysCfg to \(ecidHex)…")
                try await transport.writeRawBlob(blob)
                // Read back and verify the write took.
                let check = try await transport.readRawBlob()
                guard check == blob else { return .failed("Verification failed: the SysCfg read back after writing doesn't match what was written.") }
                onUpdate("Restore verified — the new chip now carries the unit's original SysCfg.")
                return .restored
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
