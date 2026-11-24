import Foundation

// MARK: - NAND controller statistics (lockdown `com.apple.disk_usage` / `NANDInfo`)
//
// A HomePod booted into audioOS with the USB adapter attached answers lockdown
// over USB, and the domain `com.apple.disk_usage` key `NANDInfo` returns the
// NAND controller's (ASP) lifetime statistics:
//
//     ideviceinfo -q com.apple.disk_usage -k NANDInfo        (base64)
//     ideviceinfo -q com.apple.disk_usage -k NANDInfo -x     (plist <data>)
//
// Apple's own `gather_nand_info` / `gather_nand_csv` read the same thing.
//
// Layout: a run of little-endian records `u32 key, u32 count, count × u64`.
// All-zero words can sit between records (a padding gap was seen after key
// 326 on a real B238a) and fill the rest of the buffer after the last one. The
// key numbers below follow Apple's ASP FTL stats parser; only the counters the
// app shows are named.

public struct ASPStats: Equatable, Sendable {
    public enum Key: UInt32, CaseIterable, Sendable {
        case version = 1
        case hostWrites = 4
        case hostReads = 7
        case shutdowns = 9
        case boots = 10
        case uncleanBoots = 11
        case wearLevMoves = 17
        case nandWrites = 18
        case nandReads = 19
        case bandErases = 20
        case numPfail = 22
        case numEfail = 23
        case powerOnHours = 34
        case smartCritWarnings = 36
        case maxHighEnduranceBlockErases = 45
        case numFactoryBad = 46
        case numGrownBad = 47
        case numFreeVirtualBlocks = 48
        case bytesPerPage = 49
        case pagesPerVirtualBlock = 50
        case blocksPerVirtualBlock = 51
        case numVirtualBlocks = 52
        case exportVersion = 53
        case ecBins = 54
        case coldestCycle = 124
        case hottestCycle = 125
        case raidFailedReconstructionInternal = 134
        case raidFailedReconstructionHost = 135
        case bulkPFail = 167
        case bulkRFail = 169
        case internalUeccs = 182
        case e2eFail = 183
        case numSyscfgWrites = 198
        case crcInternalReadFail = 213
        case numBootBlockRefreshFail = 270
        case numBootBlockValidateFail = 315
        case numFirmwareWrites = 334
        case numCrossTempUecc = 340
        case utilUeccReads = 343
        case clogLastStripeUeccs = 353
        case numRetiredBlocks = 379
        case ueccReads = 414
    }

    /// Every record, by key number. Unnamed keys are kept too.
    public let records: [UInt32: [UInt64]]

    public init(records: [UInt32: [UInt64]]) { self.records = records }

    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case malformed(offset: Int)
        case notNANDInfo(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "The HomePod returned no NAND statistics."
            case .malformed(let offset): return "The NAND statistics are malformed (at byte \(offset))."
            case .notNANDInfo(let text): return "That isn't NAND statistics: \(text)"
            }
        }
    }

    /// Decode the raw `NANDInfo` blob.
    public static func parse(_ data: Data) throws -> ASPStats {
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }

        var records: [UInt32: [UInt64]] = [:]
        var off = 0
        while off + 8 <= b.count {
            let key = u32(off), count = Int(u32(off + 4))
            if key == 0 {
                // Padding: skip zero words until the next record (or the end).
                guard count == 0 else { throw ParseError.malformed(offset: off) }
                var next = off
                while next + 4 <= b.count, u32(next) == 0 { next += 4 }
                if next + 8 > b.count { break }
                off = next
                continue
            }
            guard count > 0, count <= 4096, off + 8 + 8 * count <= b.count else {
                if records.isEmpty { throw ParseError.malformed(offset: off) }
                break   // keep what decoded cleanly
            }
            records[key] = (0..<count).map { u64(off + 8 + 8 * $0) }
            off += 8 + 8 * count
        }
        guard !records.isEmpty else { throw ParseError.empty }
        return ASPStats(records: records)
    }

    /// Decode what `ideviceinfo -q com.apple.disk_usage -k NANDInfo` printed:
    /// a plist with a `<data>` value (with `-x`) or a bare base64 line.
    public static func parse(ideviceinfoOutput text: String) throws -> ASPStats {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist"),
           let raw = trimmed.data(using: .utf8),
           let value = try? PropertyListSerialization.propertyList(from: raw, format: nil) {
            if let data = value as? Data { return try parse(data) }
            throw ParseError.notNANDInfo("the reply holds no data value")
        }
        // Base64 can come wrapped over several lines; ideviceinfo's own errors
        // are words ("ERROR: …", "No device found").
        let joined = trimmed.split(whereSeparator: \.isNewline).joined()
        guard !joined.isEmpty, joined.allSatisfy({ $0.isLetter || $0.isNumber || "+/=".contains($0) }),
              let data = Data(base64Encoded: String(joined)) else {
            throw ParseError.notNANDInfo(String(trimmed.prefix(200)))
        }
        return try parse(data)
    }

    public func values(_ key: Key) -> [UInt64]? { records[key.rawValue] }
    /// First value of a counter.
    public func value(_ key: Key) -> UInt64? { records[key.rawValue]?.first }
    /// Sum of an array counter (per-die / per-channel totals).
    public func total(_ key: Key) -> UInt64? { records[key.rawValue].map { $0.reduce(0, &+) } }

    /// Bytes in one virtual block (a "band"): page size × pages per block.
    public var bytesPerVirtualBlock: UInt64? {
        guard let page = value(.bytesPerPage), let pages = value(.pagesPerVirtualBlock), page > 0, pages > 0 else { return nil }
        return page * pages
    }

    /// Raw flash size the controller manages.
    public var rawCapacityBytes: UInt64? {
        guard let per = bytesPerVirtualBlock, let n = value(.numVirtualBlocks), n > 0 else { return nil }
        return per * n
    }

    /// Average program/erase cycles per block: band erases ÷ blocks.
    public var averageEraseCycles: Double? {
        guard let erases = value(.bandErases), let n = value(.numVirtualBlocks), n > 0 else { return nil }
        return Double(erases) / Double(n)
    }
}

// MARK: - Health summary

public struct NANDHealthReport: Equatable, Sendable {
    public enum Verdict: String, Sendable { case good, warning, failing }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String { label }
        public let label: String
        public let value: String
        public let note: String?
        /// Set on rows that drove the verdict.
        public let flag: Verdict?
    }

    public let verdict: Verdict
    public let headline: String
    public let rows: [Row]
    /// Error counters that aren't zero, as "label: n".
    public let problems: [String]

    /// Error counters, worst first. A nonzero "failing" counter means the
    /// controller lost data it couldn't rebuild; the rest it worked around.
    static let errorCounters: [(ASPStats.Key, String, Verdict)] = [
        (.smartCritWarnings, "Critical warnings", .failing),
        (.raidFailedReconstructionHost, "Unrecoverable stripes (user data)", .failing),
        (.ueccReads, "Uncorrectable reads", .failing),
        (.numGrownBad, "Grown bad blocks", .warning),
        (.numRetiredBlocks, "Retired blocks", .warning),
        (.numPfail, "Program failures", .warning),
        (.numEfail, "Erase failures", .warning),
        (.bulkPFail, "Program failures (bulk)", .warning),
        (.bulkRFail, "Read failures (bulk)", .warning),
        (.internalUeccs, "Uncorrectable reads (internal)", .warning),
        (.utilUeccReads, "Uncorrectable reads (metadata)", .warning),
        (.numCrossTempUecc, "Uncorrectable reads (temperature)", .warning),
        (.clogLastStripeUeccs, "Uncorrectable reads (log)", .warning),
        (.e2eFail, "End-to-end data check failures", .warning),
        (.raidFailedReconstructionInternal, "Unrecoverable stripes (internal)", .warning),
        (.crcInternalReadFail, "CRC read failures", .warning),
        (.numBootBlockRefreshFail, "Boot-block refresh failures", .warning),
        (.numBootBlockValidateFail, "Boot-block check failures", .warning),
    ]

    public init(stats s: ASPStats) {
        var rows: [Row] = []
        var problems: [String] = []
        var verdict = Verdict.good
        var failing: [String] = []

        for (key, label, severity) in Self.errorCounters {
            guard let n = s.total(key), n > 0 else { continue }
            problems.append("\(label): \(n)")
            if severity == .failing {
                failing.append(label.lowercased())
                verdict = .failing
            } else if verdict == .good {
                verdict = .warning
            }
            // Grown bad blocks already show in the "Bad blocks" row.
            if key != .numGrownBad { rows.append(Row(label: label, value: "\(n)", note: nil, flag: severity)) }
        }

        if let factory = s.value(.numFactoryBad) {
            let grown = s.value(.numGrownBad) ?? 0
            rows.insert(Row(label: "Bad blocks", value: "\(factory) from the factory, \(grown) since",
                            note: "Factory bad blocks are marked when the chip is made and are normal. Blocks that went bad later are the ones to watch.",
                            flag: grown > 0 ? .warning : nil), at: 0)
        }
        if let avg = s.averageEraseCycles {
            var v = String(format: "~%.0f erase cycles per block", avg)
            if let hot = s.value(.hottestCycle), let cold = s.value(.coldestCycle) {
                v += " (busiest \(hot), quietest \(cold))"
            }
            rows.append(Row(label: "Wear", value: v,
                            note: "How many times, on average, each block has been erased and rewritten.", flag: nil))
        }
        if let nand = s.value(.nandWrites) {
            var v = Self.bytes(nand * 4096)
            if let host = s.value(.hostWrites) { v += " (\(Self.bytes(host * 4096)) asked for by the system)" }
            rows.append(Row(label: "Written to flash", value: v, note: nil, flag: nil))
        }
        if let cap = s.rawCapacityBytes, let n = s.value(.numVirtualBlocks), let per = s.bytesPerVirtualBlock {
            rows.append(Row(label: "Raw flash", value: "\(Self.bytes(cap)) (\(n) blocks of \(per / 1_048_576) MB)", note: nil, flag: nil))
        }
        if let hours = s.value(.powerOnHours) {
            rows.append(Row(label: "Power-on time", value: "\(hours) hours", note: nil, flag: nil))
        }
        if let boots = s.value(.boots) {
            let unclean = s.value(.uncleanBoots).map { " (\($0) after power was cut)" } ?? ""
            rows.append(Row(label: "Boots", value: "\(boots)\(unclean)",
                            note: "Boots after power was cut are normal for a speaker that gets unplugged.", flag: nil))
        }
        if let w = s.value(.numSyscfgWrites) {
            rows.append(Row(label: "SysCfg writes", value: "\(w)",
                            note: "How many times the identity/calibration area (SysCfg) has been rewritten.", flag: nil))
        }

        let headline: String
        switch verdict {
        case .good:
            headline = "No grown bad blocks or flash errors recorded."
        case .warning:
            headline = "The flash has started to develop errors, which the controller has worked around so far: " + problems.joined(separator: ", ") + "."
        case .failing:
            headline = "The flash is failing (" + failing.joined(separator: ", ") + "). Back up anything you need, and expect restores to fail."
        }
        self.verdict = verdict
        self.headline = headline
        self.rows = rows
        self.problems = problems
    }

    /// Decimal units, as drive makers count them: "9.0 TB", "17.7 GB".
    static func bytes(_ n: UInt64) -> String {
        let d = Double(n)
        if d >= 1e12 { return String(format: "%.1f TB", d / 1e12) }
        if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
        return String(format: "%.0f MB", d / 1e6)
    }

    /// The report as plain text, for copying into a support message.
    public var plainText: String {
        var lines = ["NAND health: \(verdict.rawValue)", headline, ""]
        for r in rows { lines.append("\(r.label): \(r.value)") }
        return lines.joined(separator: "\n")
    }
}
