import Foundation

// MARK: - Full diagnostics data model
//
// The on-pod `hpdiag-*` scripts (shipped in the SSH-ramdisk overlay) each print
// ONE JSON object describing one subsystem. The types below are the Mac-side
// mirror of those objects, plus the display rows the UI shows for them.
//
// Design note — why decoding is deliberately lenient:
// Several of the on-pod property names are still "to confirm on a known-good
// pod" (thermal channels, PMU rails; the NAND keys ARE confirmed against a real
// registry dump — see NANDHealth). A script that can't find
// a value omits the key, and an early script revision may emit a number as a
// string ("0x1c", "4194304") or a size as free text ("16 GB"). None of that
// should turn a whole report into a decode error, so EVERY key is optional and
// numbers / bools / strings are coerced where the meaning is unambiguous. A
// missing value simply produces no row; it never produces a fake one.
//
// Design note — who owns the verdict:
// The script reports its own `verdict`. The Mac side also derives one from the
// decoded numbers using the documented thresholds, and the final `verdict` is
// the WORSE of the two. That way a stale script can't call a chip with
// I/O errors "pass", and a script that knows more than we do (e.g. a
// read-retry heuristic) can still escalate.

/// Verdict for any diagnostic tool.
public enum DiagVerdict: String, Codable, Sendable, CaseIterable {
    case pass, warn, fail, info

    /// Ordering used when combining verdicts: info < pass < warn < fail.
    public var severity: Int {
        switch self {
        case .info: return 0
        case .pass: return 1
        case .warn: return 2
        case .fail: return 3
        }
    }

    /// Short upper-case tag for plain-text reports ("PASS", "WARN", …).
    public var tag: String { rawValue.uppercased() }

    /// The most severe of `verdicts`; `.info` when the list is empty.
    public static func worst(_ verdicts: [DiagVerdict]) -> DiagVerdict {
        verdicts.max { $0.severity < $1.severity } ?? .info
    }

    /// Lenient parse of a script-reported verdict ("PASS", "ok", "warning"…).
    public init?(lenient text: String) {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pass", "ok", "good", "passed": self = .pass
        case "warn", "warning": self = .warn
        case "fail", "failed", "error", "bad": self = .fail
        case "info", "unknown", "n/a", "na", "skip", "skipped": self = .info
        default: return nil
        }
    }
}

/// A single row in the diagnostics report.
public struct DiagRow: Codable, Identifiable, Sendable, Equatable {
    /// Stable identifier, e.g. "nand.ioErrors".
    public let id: String
    /// Human label, e.g. "I/O Errors".
    public let label: String
    /// Display value, e.g. "read 0, write 0".
    public let value: String
    public let verdict: DiagVerdict
    /// Optional explanation shown under the value.
    public let note: String?

    public init(id: String, label: String, value: String, verdict: DiagVerdict, note: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.verdict = verdict
        self.note = note
    }
}

/// UI grouping for the report.
public enum DiagSubsystem: String, Codable, Sendable, CaseIterable, Identifiable {
    case storage, factory, environment, audio, sensors

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .storage: return "Storage"
        case .factory: return "Factory"
        case .environment: return "Environment"
        case .audio: return "Audio"
        case .sensors: return "Sensors"
        }
    }
}

/// One on-pod diagnostic script.
public enum DiagTool: String, Codable, Sendable, CaseIterable, Identifiable {
    case nand, partmap, factory, thermal, power, radio, audio, mic, accel

    public var id: String { rawValue }

    /// What the tech sees while this tool runs.
    public var title: String {
        switch self {
        case .nand: return "NAND health"
        case .partmap: return "Storage layout"
        case .factory: return "Factory data"
        case .thermal: return "Temperature"
        case .power: return "Power"
        case .radio: return "Radios"
        case .audio: return "Audio hardware"
        case .mic: return "Microphone board"
        case .accel: return "Tap sensor"
        }
    }

    public var subsystem: DiagSubsystem {
        switch self {
        case .nand, .partmap: return .storage
        case .factory: return .factory
        case .thermal, .power, .radio: return .environment
        case .audio: return .audio
        case .mic, .accel: return .sensors
        }
    }
}

// MARK: - NAND health (hpdiag-nand)

/// Health of the raw NAND as the A8 ASP controller actually reports it.
///
/// Every field here mirrors a property that exists in a real AudioAccessory1,1
/// IORegistry (ramdisk boot, Toshiba 15 nm MLC). There are deliberately NO
/// wear / spare-block / bad-block / erase-count / uncorrectable-error fields:
/// this controller does not publish any such counter, so an earlier revision
/// that modelled them could only ever show nothing. What does exist:
///
/// - `ASPStorage."AppleNANDStatus"` — a string, "Ready" on a healthy chip.
/// - `ASPStorage."Device Characteristics"` — one dictionary of identity and
///   geometry: `vendor-name`, `nand-marketing-name`, `chip-id`,
///   `manufacturer-id`, `firmware-version`, `capacity`, `caus`,
///   `blocks-per-cau`, `package_blocks_at_EOL`, `pages-per-block-mlc`,
///   `pages-per-block-slc`, `default-bits-per-cell`, `#page-bytes`.
/// - `ASPStorage."Controller Characteristics"` — `Encryption Type`.
/// - `IOBlockStorageDriver."Statistics"` — per whole disk: `Errors (Read)`,
///   `Errors (Write)`, `Retries (Read)`, `Retries (Write)`,
///   `Operations (Read)`, `Operations (Write)`, `Bytes (Read)`, `Bytes (Write)`.
///
/// Health is therefore judged from the controller status and the block-layer
/// error / retry counters of the main NAND disk — not from SMART-style wear.
public struct NANDHealth: Codable, Sendable, Equatable {
    /// Block-layer I/O statistics for one whole disk (the main NAND, or the
    /// Firmware / LLB / PanicLog regions), from `IOBlockStorageDriver`.
    public struct Disk: Codable, Sendable, Equatable, Identifiable {
        /// BSD name, e.g. "disk0". Device numbers differ between pods.
        public let bsd: String
        /// IOMedia node name, e.g. "Apple NAND Media", "Apple PanicLog Media".
        public let media: String?
        public let errorsRead: Int?
        public let errorsWrite: Int?
        public let retriesRead: Int?
        public let retriesWrite: Int?
        public let opsRead: Int?
        public let opsWrite: Int?
        public let bytesRead: Int?
        public let bytesWrite: Int?

        public var id: String { bsd }

        /// Read + write errors; `nil` when the driver reported neither.
        public var errorTotal: Int? {
            if errorsRead == nil && errorsWrite == nil { return nil }
            return (errorsRead ?? 0) + (errorsWrite ?? 0)
        }

        /// Read + write retries; `nil` when the driver reported neither.
        public var retryTotal: Int? {
            if retriesRead == nil && retriesWrite == nil { return nil }
            return (retriesRead ?? 0) + (retriesWrite ?? 0)
        }

        /// The main NAND is identified by its media name, never its number.
        public var isMainNAND: Bool { (media ?? "").lowercased().contains("nand media") }

        enum CodingKeys: String, CodingKey {
            case bsd, media, errorsRead, errorsWrite, retriesRead, retriesWrite
            case opsRead, opsWrite, bytesRead, bytesWrite
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bsd = c.diagString(.bsd) ?? "?"
            media = c.diagString(.media)
            errorsRead = c.diagInt(.errorsRead)
            errorsWrite = c.diagInt(.errorsWrite)
            retriesRead = c.diagInt(.retriesRead)
            retriesWrite = c.diagInt(.retriesWrite)
            opsRead = c.diagInt(.opsRead)
            opsWrite = c.diagInt(.opsWrite)
            bytesRead = c.diagInt(.bytesRead)
            bytesWrite = c.diagInt(.bytesWrite)
        }
    }

    public let ok: Bool
    /// IORegistry class the figures came from ("ASPStorage").
    public let source: String?

    // ASPStorage top-level
    /// `AppleNANDStatus` — "Ready" on a healthy chip.
    public let nandStatus: String?
    /// `Controller Characteristics` → `Encryption Type`, e.g. "AES-CBC".
    public let encryptionType: String?

    // ASPStorage "Device Characteristics" — identity
    /// `nand-marketing-name`, e.g. "15nm64Gb0C".
    public let nandMarketingName: String?
    /// `vendor-name`, e.g. "Toshiba".
    public let vendor: String?
    /// `chip-id`.
    public let chipId: String?
    /// `manufacturer-id`.
    public let manufacturerId: String?
    /// `firmware-version` of the NAND controller.
    public let firmwareVersion: String?
    /// `controller-unique-id` — the NAND's own unique ID (what the factory
    /// `nanduid` / `NANDInfoTool` report). It belongs to the chip, not the
    /// board, so it changes when the NAND is replaced.
    public let controllerUniqueId: String?
    /// The chip ID starts with ASCII "PPN" (`50 50 4E`): a PPN device.
    public let ppn: Bool?
    /// The three bytes after "PPN" in the chip ID, as "major.minor.patch".
    public let ppnVersion: String?
    /// Maker named by the JEDEC code in byte 0 of `manufacturer-id`.
    public let jedecVendor: String?
    /// `num-bus`.
    public let numBus: Int?
    /// `ce-per-bus`.
    public let cePerBus: Int?
    /// `dies-per-channel`.
    public let diesPerChannel: Int?
    /// `num-bus` × `ce-per-bus` — chip enables that answered.
    public let chipEnables: Int?

    // ASPStorage "Device Characteristics" — geometry
    /// `capacity`, in bytes.
    public let capacityBytes: Int?
    /// `caus` — chip address units.
    public let caus: Int?
    /// `blocks-per-cau`.
    public let blocksPerCau: Int?
    /// `caus` × `blocks-per-cau`.
    public let blocksTotal: Int?
    /// `package_blocks_at_EOL` — a static design figure (the block budget the
    /// package is specified to still have at end of life). NOT a live counter.
    public let packageBlocksAtEOL: Int?
    /// `pages-per-block-mlc`.
    public let pagesPerBlockMlc: Int?
    /// `pages-per-block-slc`.
    public let pagesPerBlockSlc: Int?
    /// `default-bits-per-cell` (2 = MLC).
    public let bitsPerCell: Int?
    /// `#page-bytes` — usable bytes per page.
    public let pageBytes: Int?

    // IOBlockStorageDriver "Statistics"
    /// Every whole disk the block layer reported.
    public let disks: [Disk]
    /// BSD name of the main NAND disk, resolved by media name on the pod.
    public let mainDisk: String?
    /// Main NAND disk: `Errors (Read)`.
    public let ioErrorsRead: Int?
    /// Main NAND disk: `Errors (Write)`.
    public let ioErrorsWrite: Int?
    /// Main NAND disk: `Retries (Read)`.
    public let ioRetriesRead: Int?
    /// Main NAND disk: `Retries (Write)`.
    public let ioRetriesWrite: Int?
    /// Legacy alias of `ioRetriesRead` that older scripts emitted on its own.
    public let readRetrySeen: Int?

    public let writeLocked: Bool?
    public let ramdiskRooted: Bool?
    /// The lock property verbatim, when it wasn't boolean-like.
    public let writeLockedRaw: String?
    /// The uninterpreted source text / properties the script saw — kept for the
    /// JSON export so an unrecognized ASP key is never lost.
    public let raw: DiagJSONValue?
    public let note: String?
    public let error: String?
    public let verdict: DiagVerdict

    /// The value `AppleNANDStatus` has on a healthy chip.
    public static let readyStatus = "Ready"

    enum CodingKeys: String, CodingKey {
        case ok, source, nandStatus, encryptionType
        case nandMarketingName, vendor, chipId, manufacturerId, firmwareVersion
        case controllerUniqueId, ppn, ppnVersion, jedecVendor, numBus, cePerBus, diesPerChannel, chipEnables
        case capacityBytes, caus, blocksPerCau, blocksTotal, packageBlocksAtEOL
        case pagesPerBlockMlc, pagesPerBlockSlc, bitsPerCell, pageBytes
        case disks, mainDisk, ioErrorsRead, ioErrorsWrite, ioRetriesRead, ioRetriesWrite, readRetrySeen
        case writeLocked, writeLockedRaw, ramdiskRooted, raw, note, error, verdict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let okValue = c.diagBool(.ok) ?? true
        let status = c.diagString(.nandStatus)
        let diskList: [Disk] = c.diagArray(.disks)
        let mainName = c.diagString(.mainDisk)
        let main = Self.resolveMainDisk(in: diskList, named: mainName)
        let legacyRetries = c.diagInt(.readRetrySeen)
        let caus = c.diagInt(.caus)
        let blocksPerCau = c.diagInt(.blocksPerCau)
        // The script reports the main disk's figures at the top level; fall back
        // to the per-disk entry so a partial script revision still works.
        let errRead = c.diagInt(.ioErrorsRead) ?? main?.errorsRead
        let errWrite = c.diagInt(.ioErrorsWrite) ?? main?.errorsWrite
        let retryRead = c.diagInt(.ioRetriesRead) ?? main?.retriesRead ?? legacyRetries
        let retryWrite = c.diagInt(.ioRetriesWrite) ?? main?.retriesWrite

        ok = okValue
        source = c.diagString(.source)
        nandStatus = status
        encryptionType = c.diagString(.encryptionType)
        nandMarketingName = c.diagString(.nandMarketingName)
        vendor = c.diagString(.vendor)
        chipId = c.diagString(.chipId)
        manufacturerId = c.diagString(.manufacturerId)
        firmwareVersion = c.diagString(.firmwareVersion)
        controllerUniqueId = c.diagString(.controllerUniqueId).flatMap { $0.isEmpty ? nil : $0 }
        // Older script revisions don't decode the IDs; do it here from the raw
        // strings so their reports get the same rows.
        let chipIdText = c.diagString(.chipId)
        let decodedPPN = chipIdText.flatMap(Self.ppnVersion(chipId:))
        ppn = c.diagBool(.ppn) ?? chipIdText.map { _ in decodedPPN != nil }
        ppnVersion = c.diagString(.ppnVersion) ?? decodedPPN
        jedecVendor = c.diagString(.jedecVendor) ?? c.diagString(.manufacturerId).flatMap(Self.jedecVendor(manufacturerId:))
        let buses = c.diagInt(.numBus)
        let cePerBusValue = c.diagInt(.cePerBus)
        numBus = buses
        cePerBus = cePerBusValue
        diesPerChannel = c.diagInt(.diesPerChannel)
        chipEnables = c.diagInt(.chipEnables) ?? Self.product(buses, cePerBusValue)
        capacityBytes = c.diagInt(.capacityBytes)
        self.caus = caus
        self.blocksPerCau = blocksPerCau
        blocksTotal = c.diagInt(.blocksTotal) ?? Self.product(caus, blocksPerCau)
        packageBlocksAtEOL = c.diagInt(.packageBlocksAtEOL)
        pagesPerBlockMlc = c.diagInt(.pagesPerBlockMlc)
        pagesPerBlockSlc = c.diagInt(.pagesPerBlockSlc)
        bitsPerCell = c.diagInt(.bitsPerCell)
        pageBytes = c.diagInt(.pageBytes)
        disks = diskList
        mainDisk = mainName ?? main?.bsd
        ioErrorsRead = errRead
        ioErrorsWrite = errWrite
        ioRetriesRead = retryRead
        ioRetriesWrite = retryWrite
        readRetrySeen = legacyRetries
        writeLocked = c.diagBool(.writeLocked)
        ramdiskRooted = c.diagBool(.ramdiskRooted)
        writeLockedRaw = c.diagString(.writeLockedRaw)
        raw = (try? c.decodeIfPresent(DiagJSONValue.self, forKey: .raw)) ?? nil
        note = c.diagString(.note)
        error = c.diagString(.error)
        verdict = DiagVerdict.resolve(ok: okValue, reported: c.diagVerdict(.verdict),
                                      derived: Self.derive(status: status,
                                                           errors: Self.sum(errRead, errWrite),
                                                           retries: Self.sum(retryRead, retryWrite)))
    }

    /// The main NAND disk: the one the script named, else the one whose media
    /// name says so. Never chosen by device number.
    static func resolveMainDisk(in disks: [Disk], named name: String?) -> Disk? {
        if let name, let match = disks.first(where: { $0.bsd == name }) { return match }
        return disks.first(where: { $0.isMainNAND })
    }

    static func product(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        return a * b
    }

    /// JEDEC maker codes of the NAND vendors Apple has used.
    static let jedecMakers: [String: String] = [
        "98": "Toshiba/Kioxia", "2c": "Micron", "ad": "SK hynix", "ec": "Samsung", "45": "SanDisk", "89": "Intel",
    ]

    /// Maker for a `manufacturer-id` hex string ("988260561902" → Toshiba/Kioxia).
    static func jedecVendor(manufacturerId: String) -> String? {
        jedecMakers[String(manufacturerId.lowercased().prefix(2))]
    }

    /// "1.5.8" for a PPN chip ID ("50504E010508"); `nil` when it isn't one.
    static func ppnVersion(chipId: String) -> String? {
        let hex = chipId.lowercased()
        guard hex.hasPrefix("50504e"), hex.count >= 12 else { return nil }
        let digits = Array(hex.dropFirst(6).prefix(6))
        var parts: [String] = []
        for i in stride(from: 0, to: 6, by: 2) {
            guard let v = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            parts.append(String(v))
        }
        return parts.joined(separator: ".")
    }

    /// The JEDEC maker code and the vendor string name different makers.
    /// `nil` when either is unknown.
    public var vendorMismatch: Bool? {
        guard let jedecVendor, let vendor, !vendor.isEmpty else { return nil }
        let a = jedecVendor.lowercased(), b = vendor.lowercased()
        return !(a.contains(b.prefix(5)) || b.contains(a.prefix(5)))
    }

    /// Unique ID with the middle hidden: "000006…F464".
    public static func redactedUniqueId(_ uid: String) -> String {
        uid.count > 12 ? "\(uid.prefix(6))…\(uid.suffix(4))" : uid
    }

    /// Sum of two optional counters; `nil` when neither is known.
    static func sum(_ a: Int?, _ b: Int?) -> Int? {
        if a == nil && b == nil { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    static func isReady(_ status: String) -> Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(readyStatus) == .orderedSame
    }

    /// Verdict from the real indicators alone; `nil` when none came back.
    /// - fail: `AppleNANDStatus` isn't "Ready", or the main NAND disk has I/O errors.
    /// - warn: the main NAND disk needed retries.
    static func derive(status: String?, errors: Int?, retries: Int?) -> DiagVerdict? {
        var parts: [DiagVerdict] = []
        if let status { parts.append(isReady(status) ? .pass : .fail) }
        if let errors { parts.append(errors > 0 ? .fail : .pass) }
        if let retries { parts.append(retries > 0 ? .warn : .pass) }
        return parts.isEmpty ? nil : DiagVerdict.worst(parts)
    }

    /// Main NAND disk read + write errors; `nil` when not reported.
    public var ioErrors: Int? { Self.sum(ioErrorsRead, ioErrorsWrite) }

    /// Main NAND disk read + write retries; `nil` when not reported.
    public var ioRetries: Int? { Self.sum(ioRetriesRead, ioRetriesWrite) }

    /// "Toshiba 15nm64Gb0C" from whichever identity parts are known.
    public var chipDescription: String? {
        let parts = [vendor, nandMarketingName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Whole disks other than the main NAND that reported I/O errors.
    public var otherDisksWithErrors: [Disk] {
        let mainName = mainDisk
        return disks.filter { disk in
            if let mainName, disk.bsd == mainName { return false }
            if mainName == nil, disk.isMainNAND { return false }
            return (disk.errorTotal ?? 0) > 0
        }
    }

    /// True when at least one real health indicator came back.
    public var hasHealthIndicators: Bool {
        nandStatus != nil || ioErrors != nil || ioRetries != nil
    }

    /// Display rows for the UI.
    public var rows: [DiagRow] {
        var out: [DiagRow] = []
        if let r = DiagRow.status(tool: .nand, ok: ok, error: error) { out.append(r) }
        if let nandStatus {
            let ready = Self.isReady(nandStatus)
            out.append(DiagRow(id: "nand.status.controller", label: "NAND Status", value: nandStatus,
                               verdict: ready ? .pass : .fail,
                               note: ready ? nil : "The NAND controller is not reporting Ready. This chip (or its connection) is faulty."))
        }
        if let chip = chipDescription {
            var detail: [String] = []
            if let chipId { detail.append("chip ID \(chipId)") }
            if let manufacturerId { detail.append("manufacturer ID \(manufacturerId)") }
            if let firmwareVersion { detail.append("firmware \(firmwareVersion)") }
            if let ppnVersion { detail.append("PPN \(ppnVersion)") }
            out.append(DiagRow(id: "nand.chip", label: "Chip", value: chip, verdict: .info,
                               note: detail.isEmpty ? nil : detail.joined(separator: ", ")))
        }
        if let jedecVendor {
            let mismatch = vendorMismatch == true
            out.append(DiagRow(id: "nand.maker", label: "Maker (JEDEC)", value: jedecVendor, verdict: .info,
                               note: mismatch ? "The ID bytes name a different maker than the vendor string (\(vendor ?? "?")). Worth a second look on a board that has had its NAND replaced." : nil))
        }
        if let controllerUniqueId {
            out.append(DiagRow(id: "nand.uid", label: "NAND Unique ID", value: controllerUniqueId, verdict: .info,
                               note: "Belongs to the chip, not the board — it changes when the NAND is replaced. Note it at intake to tell later whether the board still has the chip it arrived with."))
        }
        if let chipEnables {
            var value = String(chipEnables)
            if let numBus, let cePerBus { value += " (\(numBus) bus\(numBus == 1 ? "" : "es") × \(cePerBus) CE)" }
            out.append(DiagRow(id: "nand.chipEnables", label: "Chip Enables", value: value, verdict: .info,
                               note: diesPerChannel.map { "\($0) die\($0 == 1 ? "" : "s") per channel" }))
        }
        if let capacityBytes {
            out.append(DiagRow(id: "nand.capacity", label: "Capacity", value: DiagFormat.bytes(capacityBytes), verdict: .info,
                               note: blocksTotal.map { "\($0) blocks" }))
        }
        var geometry: [String] = []
        if let caus, let blocksPerCau { geometry.append("\(caus) × \(blocksPerCau) blocks") }
        if let pagesPerBlockMlc { geometry.append("\(pagesPerBlockMlc) pages/block") }
        if let pageBytes { geometry.append("\(pageBytes)-byte pages") }
        if let bitsPerCell { geometry.append("\(bitsPerCell) bits/cell") }
        if !geometry.isEmpty {
            out.append(DiagRow(id: "nand.geometry", label: "Geometry", value: geometry.joined(separator: ", "), verdict: .info))
        }
        if let packageBlocksAtEOL {
            out.append(DiagRow(id: "nand.eolBlocks", label: "End-of-Life Block Budget", value: String(packageBlocksAtEOL), verdict: .info,
                               note: "A fixed design figure from the chip's configuration, not a live wear counter."))
        }
        if let encryptionType {
            out.append(DiagRow(id: "nand.encryption", label: "Encryption", value: encryptionType, verdict: .info))
        }
        if let errors = ioErrors {
            var location = ""
            if let mainDisk { location = " on " + mainDisk }
            out.append(DiagRow(id: "nand.ioErrors", label: "I/O Errors",
                               value: "read \(ioErrorsRead ?? 0), write \(ioErrorsWrite ?? 0)",
                               verdict: errors > 0 ? .fail : .pass,
                               note: errors > 0 ? "The block layer reported failed transfers\(location). This NAND is failing." : nil))
        }
        if let retries = ioRetries {
            out.append(DiagRow(id: "nand.ioRetries", label: "I/O Retries",
                               value: "read \(ioRetriesRead ?? 0), write \(ioRetriesWrite ?? 0)",
                               verdict: retries > 0 ? .warn : .pass,
                               note: retries > 0 ? "Transfers that needed a retry but succeeded. A rising count is an early warning sign." : nil))
        }
        let others = otherDisksWithErrors
        if !others.isEmpty {
            var entries: [String] = []
            for disk in others {
                var entry = disk.bsd
                if let media = disk.media { entry += " (" + media + ")" }
                entry += ": " + String(disk.errorTotal ?? 0)
                entries.append(entry)
            }
            let text = entries.joined(separator: ", ")
            out.append(DiagRow(id: "nand.otherRegionErrors", label: "Other Region Errors", value: text, verdict: .info,
                               note: "Errors on the Firmware / LLB / PanicLog regions aren't counted against the NAND. A short or empty panic-log region commonly reports read errors."))
        }
        if let writeLocked {
            out.append(DiagRow(id: "nand.writeLocked", label: "Write Lock", value: writeLocked ? "Locked" : "Unlocked", verdict: .info,
                               note: writeLocked && ramdiskRooted == true ? "Expected while booted from the ramdisk." : nil))
        }
        if writeLocked == nil, let writeLockedRaw {
            out.append(DiagRow(id: "nand.writeLocked", label: "Write Lock", value: writeLockedRaw, verdict: .info))
        }
        if ok {
            if hasHealthIndicators {
                out.append(DiagRow(id: "nand.wearCounters", label: "Wear Counters", value: "Not published", verdict: .info,
                                   note: "This NAND controller exposes no wear, spare-block, bad-block or erase-count figures to the ramdisk. Health is judged from the controller status and I/O errors."))
            } else {
                out.append(DiagRow(id: "nand.noCounters", label: "Health Indicators", value: "None recognized", verdict: .info,
                                   note: "The NAND nodes answered, but neither the controller status nor I/O statistics were found. The raw properties are in the JSON export."))
            }
        }
        if let source {
            out.append(DiagRow(id: "nand.source", label: "Data Source", value: source, verdict: .info))
        }
        if let r = DiagRow.note(tool: .nand, note) { out.append(r) }
        return out
    }
}

// MARK: - Partition map (hpdiag-partmap)

/// Which block devices exist, whether they read, and whether the firmware
/// region carries valid Apple container magic.
public struct PartitionMap: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable, Identifiable {
        /// Device node, e.g. "/dev/rdisk2".
        public let dev: String
        public let readable: Bool?
        /// "block" or "char".
        public let node: String?
        /// Bytes that came back from the script's 1 MiB probe read. This is a
        /// readability probe, NOT the size of the device.
        public let bytes: Int?
        /// `bytes` as free text when it wasn't a number.
        public let sizeText: String?
        /// Detected role: "apfs-encrypted", "firmware", "panic-log", …
        public let type: String?
        /// The region parsed as an IMG4/IM4P container.
        public let img4: Bool?
        /// Leading magic bytes as the script printed them.
        public let magic: String?
        /// Marker strings found in the region ("iBoot", "Util_Find_SysCfg"…).
        public let markers: [String]
        /// The region read back blank (normal for the panic log on a healthy pod).
        public let empty: Bool?

        public var id: String { dev }

        /// Device name without the "/dev/" prefix.
        public var shortName: String { dev.hasPrefix("/dev/") ? String(dev.dropFirst(5)) : dev }

        public var isFirmware: Bool { (type ?? "").lowercased().contains("firmware") }

        enum CodingKeys: String, CodingKey {
            case dev, node, readable, bytes, sizeText, type, img4, magic, markers, empty
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dev = c.diagString(.dev) ?? "?"
            node = c.diagString(.node)
            readable = c.diagBool(.readable)
            bytes = c.diagInt(.bytes)
            // "bytes" may be free text; keep it for display.
            sizeText = c.diagString(.sizeText) ?? (bytes == nil ? c.diagString(.bytes) : nil)
            type = c.diagString(.type)
            img4 = c.diagBool(.img4)
            magic = c.diagString(.magic)
            markers = c.diagStrings(.markers)
            empty = c.diagBool(.empty)
        }

        /// Row verdict for this device alone.
        public var verdict: DiagVerdict {
            // Warnings, not failures: a blank firmware region is the normal
            // state of a freshly swapped chip, and the script escalates the
            // cases that really are fatal (no main storage device).
            if readable == false { return .warn }
            if isFirmware, img4 == false { return .warn }
            return readable == true ? .pass : .info
        }
    }

    public let ok: Bool
    public let devices: [Device]
    /// Every device the layout expects showed up.
    public let expectedPresent: Bool?
    /// The firmware region (LLB/iBoot) carries a valid container.
    public let firmwareValid: Bool?
    /// The panic-log region holds panic text (the pod has crashed before).
    public let panicLogHasPanic: Bool?
    public let note: String?
    public let error: String?
    public let verdict: DiagVerdict

    enum CodingKeys: String, CodingKey {
        case ok, devices, expectedPresent, firmwareValid, panicLogHasPanic, note, error, verdict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.diagBool(.ok) ?? true
        devices = c.diagArray(.devices)
        expectedPresent = c.diagBool(.expectedPresent)
        firmwareValid = c.diagBool(.firmwareValid)
        panicLogHasPanic = c.diagBool(.panicLogHasPanic)
        note = c.diagString(.note)
        error = c.diagString(.error)

        var parts = devices.map(\.verdict).filter { $0 != .info }
        if let expectedPresent { parts.append(expectedPresent ? .pass : .warn) }
        if let firmwareValid { parts.append(firmwareValid ? .pass : .warn) }
        if panicLogHasPanic == true { parts.append(.warn) }
        verdict = DiagVerdict.resolve(ok: ok, reported: c.diagVerdict(.verdict),
                                      derived: parts.isEmpty ? nil : DiagVerdict.worst(parts))
    }

    public var rows: [DiagRow] {
        var out: [DiagRow] = []
        if let r = DiagRow.status(tool: .partmap, ok: ok, error: error) { out.append(r) }
        if let expectedPresent {
            out.append(DiagRow(id: "partmap.expectedPresent", label: "Expected Devices",
                               value: expectedPresent ? "All present" : "Incomplete",
                               verdict: expectedPresent ? .pass : .warn,
                               note: expectedPresent ? nil : "A block device the HomePod layout needs didn't show up — check the NAND seating / swap."))
        }
        if let firmwareValid {
            out.append(DiagRow(id: "partmap.firmwareValid", label: "Firmware Region",
                               value: firmwareValid ? "Valid" : "No img4 found",
                               verdict: firmwareValid ? .pass : .warn,
                               note: firmwareValid ? nil : "No LLB/iBoot container found. Normal on a blank replacement chip; the pod won't boot on its own until it is restored."))
        }
        if let panic = panicLogHasPanic {
            out.append(DiagRow(id: "partmap.panicLog", label: "Panic Log", value: panic ? "Contains a panic" : "Empty",
                               verdict: panic ? .warn : .pass,
                               note: panic ? "The pod has crashed before. Pull diagnostics to save the panic log." : nil))
        }
        for d in devices {
            var parts: [String] = []
            if d.readable == false { parts.append("not readable") }
            if d.readable != false {
                if let b = d.bytes { parts.append("read \(DiagFormat.bytes(b))") } else if let s = d.sizeText { parts.append(s) }
            }
            if let img4 = d.img4 { parts.append(img4 ? "img4 OK" : "no img4") }
            if d.empty == true { parts.append("blank") }
            var notes: [String] = []
            if !d.markers.isEmpty { notes.append("Markers: " + d.markers.joined(separator: ", ")) }
            if let m = d.magic, !m.isEmpty { notes.append("Magic: " + m) }
            let label = d.type.map { "\(d.shortName) (\($0))" } ?? d.shortName
            out.append(DiagRow(id: "partmap.\(d.shortName)", label: label,
                               value: parts.isEmpty ? "—" : parts.joined(separator: ", "),
                               verdict: d.verdict, note: notes.isEmpty ? nil : notes.joined(separator: " · ")))
        }
        if let r = DiagRow.note(tool: .partmap, note) { out.append(r) }
        return out
    }
}

// MARK: - Factory data (hpdiag-factory)

/// Completeness of the per-unit factory data: SysCfg tags and effaceable lockers.
public struct FactoryData: Codable, Sendable, Equatable {
    public struct Locker: Codable, Sendable, Equatable, Identifiable {
        public let tag: String
        public let present: Bool?
        public let bytes: Int?

        public var id: String { tag }

        enum CodingKeys: String, CodingKey { case tag, present, bytes }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tag = c.diagString(.tag) ?? "?"
            present = c.diagBool(.present)
            bytes = c.diagInt(.bytes)
        }
    }

    public let ok: Bool
    /// SysCfg container signature as stored ("gfCS" = "SCfg" reversed).
    public let sysCfgSig: String?
    public let sysCfgBytes: Int?
    public let tagsPresent: [String]
    public let tagsMissing: [String]
    public let lockers: [Locker]
    /// Serial number, when the script reports it (keys the report to the unit).
    public let serial: String?
    public let note: String?
    public let error: String?
    public let verdict: DiagVerdict

    /// Signatures accepted as a real SysCfg container (stored and forward form).
    public static let validSignatures = ["gfCS", "SCfg"]

    enum CodingKeys: String, CodingKey {
        case ok, sysCfgSig, sysCfgBytes, tagsPresent, tagsMissing, lockers, serial, note, error, verdict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.diagBool(.ok) ?? true
        sysCfgSig = c.diagString(.sysCfgSig)
        sysCfgBytes = c.diagInt(.sysCfgBytes)
        tagsPresent = c.diagStrings(.tagsPresent)
        tagsMissing = c.diagStrings(.tagsMissing)
        lockers = c.diagArray(.lockers)
        serial = c.diagString(.serial).flatMap { $0.isEmpty ? nil : $0 }
        note = c.diagString(.note)
        error = c.diagString(.error)

        var parts: [DiagVerdict] = []
        if let sig = sysCfgSig { parts.append(Self.validSignatures.contains(sig) ? .pass : .warn) }
        if !tagsPresent.isEmpty || !tagsMissing.isEmpty {
            let essentialMissing = tagsMissing.contains { SysCfgData.essentialTags.contains($0) }
            parts.append(essentialMissing ? .fail : (tagsMissing.isEmpty ? .pass : .warn))
        }
        if lockers.contains(where: { $0.present == false }) { parts.append(.warn) }
        verdict = DiagVerdict.resolve(ok: ok, reported: c.diagVerdict(.verdict),
                                      derived: parts.isEmpty ? nil : DiagVerdict.worst(parts))
    }

    /// The container signature is one we recognize; `nil` when not reported.
    public var signatureValid: Bool? { sysCfgSig.map { Self.validSignatures.contains($0) } }

    /// Missing tags that carry the unit's identity (serial / Wi-Fi / Bluetooth).
    public var essentialTagsMissing: [String] {
        tagsMissing.filter { SysCfgData.essentialTags.contains($0) }
    }

    public var rows: [DiagRow] {
        var out: [DiagRow] = []
        if let r = DiagRow.status(tool: .factory, ok: ok, error: error) { out.append(r) }
        if let sig = sysCfgSig {
            let valid = signatureValid == true
            out.append(DiagRow(id: "factory.signature", label: "SysCfg Signature", value: sig.isEmpty ? "(none)" : sig,
                               verdict: valid ? .pass : .warn,
                               note: valid ? nil : "No SysCfg signature — the factory data block is blank or damaged."))
        }
        if let n = sysCfgBytes {
            out.append(DiagRow(id: "factory.bytes", label: "SysCfg Size", value: "\(n) bytes", verdict: .info))
        }
        if !tagsPresent.isEmpty {
            out.append(DiagRow(id: "factory.tagsPresent", label: "Tags Present", value: String(tagsPresent.count), verdict: .pass,
                               note: tagsPresent.joined(separator: ", ")))
        }
        if !tagsMissing.isEmpty {
            let essential = essentialTagsMissing
            out.append(DiagRow(id: "factory.tagsMissing", label: "Tags Missing", value: tagsMissing.joined(separator: ", "),
                               verdict: essential.isEmpty ? .warn : .fail,
                               note: essential.isEmpty
                                   ? "Identity tags are intact, but some expected factory tags are absent."
                                   : "Identity tags missing (\(essential.joined(separator: ", "))) — the unit won't activate until its own SysCfg is restored."))
        } else if !tagsPresent.isEmpty {
            out.append(DiagRow(id: "factory.tagsMissing", label: "Tags Missing", value: "None", verdict: .pass))
        }
        for l in lockers {
            let present = l.present
            var value = present == true ? "Present" : (present == false ? "Missing" : "Unknown")
            if let b = l.bytes, present != false { value += " (\(b) bytes)" }
            out.append(DiagRow(id: "factory.locker.\(l.tag)", label: "Locker \(l.tag)", value: value,
                               verdict: present == true ? .pass : (present == false ? .warn : .info)))
        }
        if let r = DiagRow.note(tool: .factory, note) { out.append(r) }
        return out
    }
}

// MARK: - Thermal snapshot (hpdiag-thermal)

/// Temperatures readable at ramdisk time. Idle-ramdisk readings, not a load test.
public struct ThermalSnapshot: Codable, Sendable, Equatable {
    public struct Sensor: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        /// Raw value as published (may be ADC counts).
        public let raw: Double?
        /// Best-effort temperature in °C.
        public let celsius: Double?
        /// True only when the scale factor for this channel is confirmed.
        public let calibrated: Bool

        public var id: String { name }

        enum CodingKeys: String, CodingKey { case name, raw, celsius, calibrated }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.diagString(.name) ?? "sensor"
            raw = c.diagDouble(.raw)
            celsius = c.diagDouble(.celsius)
            calibrated = c.diagBool(.calibrated) ?? false
        }

        /// Only calibrated readings are judged; uncalibrated ones are shown as info.
        public var verdict: DiagVerdict {
            guard calibrated, let t = celsius else { return .info }
            if t < ThermalSnapshot.plausibleRange.lowerBound || t > ThermalSnapshot.plausibleRange.upperBound { return .warn }
            return t >= ThermalSnapshot.failCelsius ? .fail : (t >= ThermalSnapshot.warnCelsius ? .warn : .pass)
        }
    }

    public let ok: Bool
    public let sensors: [Sensor]
    /// Hottest reading as reported by the script.
    public let maxCelsius: Double?
    public let note: String?
    public let error: String?
    public let verdict: DiagVerdict

    /// Idle-ramdisk thresholds — conservative on purpose.
    public static let warnCelsius = 70.0
    public static let failCelsius = 90.0
    /// A calibrated reading outside this range is a sensor fault, not a temperature.
    public static let plausibleRange: ClosedRange<Double> = -10...125

    enum CodingKeys: String, CodingKey { case ok, sensors, maxCelsius, note, error, verdict }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.diagBool(.ok) ?? true
        sensors = c.diagArray(.sensors)
        maxCelsius = c.diagDouble(.maxCelsius)
        note = c.diagString(.note)
        error = c.diagString(.error)
        let parts = sensors.map(\.verdict).filter { $0 != .info }
        verdict = DiagVerdict.resolve(ok: ok, reported: c.diagVerdict(.verdict),
                                      derived: parts.isEmpty ? nil : DiagVerdict.worst(parts))
    }

    /// Hottest reading: the script's figure, else the max over the sensors.
    public var hottestCelsius: Double? { maxCelsius ?? sensors.compactMap(\.celsius).max() }

    public var rows: [DiagRow] {
        var out: [DiagRow] = []
        if let r = DiagRow.status(tool: .thermal, ok: ok, error: error) { out.append(r) }
        if ok, sensors.isEmpty {
            out.append(DiagRow(id: "thermal.none", label: "Temperature", value: "No sensors readable", verdict: .info,
                               note: "The restore ramdisk didn't publish any thermal channels."))
        }
        for s in sensors {
            let value: String
            if let t = s.celsius { value = DiagFormat.celsius(t) + (s.calibrated ? "" : " (uncalibrated)") }
            else if let raw = s.raw { value = "raw \(DiagFormat.number(raw))" }
            else { value = "—" }
            var note: String?
            let v = s.verdict
            if !s.calibrated {
                note = s.raw.map { "Raw \(DiagFormat.number($0)); scale not confirmed, so not judged." } ?? "Scale not confirmed, so not judged."
            } else if let t = s.celsius, !Self.plausibleRange.contains(t) {
                note = "Implausible reading — suspect the sensor or its flex."
            } else if v == .fail || v == .warn {
                note = "Hot for an idle ramdisk — check the thermal pads and the power supply."
            }
            out.append(DiagRow(id: "thermal.\(s.name)", label: s.name, value: value, verdict: v, note: note))
        }
        if let r = DiagRow.note(tool: .thermal, note) { out.append(r) }
        return out
    }
}

// MARK: - Power (hpdiag-power)

/// PSU / PMU view: USB link quality and whatever the PMU publishes.
public struct PowerStatus: Codable, Sendable, Equatable {
    public struct USB: Codable, Sendable, Equatable {
        /// "low", "full", "high" or "super".
        public let speed: String?
        /// The pod stayed enumerated for the whole probe.
        public let stable: Bool?

        enum CodingKeys: String, CodingKey { case speed, stable }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            speed = c.diagString(.speed)
            stable = c.diagBool(.stable)
        }

        /// High speed or better; `nil` when the speed isn't a known word.
        public var isHighSpeed: Bool? {
            guard let s = speed?.lowercased() else { return nil }
            if s.contains("high") || s.contains("super") || s.contains("480") { return true }
            if s.contains("full") || s.contains("low") || s.contains("12") || s.contains("1.5") { return false }
            return nil
        }
    }

    public struct Rail: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        /// The rail's value. Millivolts only when `unit` says so (or is absent).
        public let mv: Int?
        /// "mv", or "raw" while the PMU's scale is unconfirmed.
        public let unit: String?

        public var id: String { name }

        enum CodingKeys: String, CodingKey { case name, mv, unit }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.diagString(.name) ?? "rail"
            mv = c.diagInt(.mv)
            unit = c.diagString(.unit)
        }

        /// The value is a confirmed millivolt figure.
        public var isMillivolts: Bool { unit == nil || unit?.lowercased() == "mv" }

        public var displayValue: String {
            guard let mv else { return "—" }
            return isMillivolts ? "\(mv) mV" : "\(mv) (raw)"
        }
    }

    public struct PMU: Codable, Sendable, Equatable {
        /// IORegistry node the data came from (e.g. "AppleARMPMU").
        public let node: String?
        public let rails: [Rail]
        public let bootFlags: String?

        enum CodingKeys: String, CodingKey { case node, rails, bootFlags }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            node = c.diagString(.node)
            rails = c.diagArray(.rails)
            bootFlags = c.diagString(.bootFlags)
        }
    }

    public let ok: Bool
    public let usb: USB?
    public let pmu: PMU?
    public let note: String?
    public let error: String?
    public let verdict: DiagVerdict

    enum CodingKeys: String, CodingKey { case ok, usb, pmu, note, error, verdict }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.diagBool(.ok) ?? true
        usb = (try? c.decodeIfPresent(USB.self, forKey: .usb)) ?? nil
        pmu = (try? c.decodeIfPresent(PMU.self, forKey: .pmu)) ?? nil
        note = c.diagString(.note)
        error = c.diagString(.error)

        var parts: [DiagVerdict] = []
        if let stable = usb?.stable { parts.append(stable ? .pass : .warn) }
        if let high = usb?.isHighSpeed { parts.append(high ? .pass : .warn) }
        if let pmu, pmu.node != nil || !pmu.rails.isEmpty || pmu.bootFlags != nil { parts.append(.pass) }
        verdict = DiagVerdict.resolve(ok: ok, reported: c.diagVerdict(.verdict),
                                      derived: parts.isEmpty ? nil : DiagVerdict.worst(parts))
    }

    public var rows: [DiagRow] {
        var out: [DiagRow] = []
        if let r = DiagRow.status(tool: .power, ok: ok, error: error) { out.append(r) }
        if let usb {
            if let speed = usb.speed {
                let high = usb.isHighSpeed
                out.append(DiagRow(id: "power.usb.speed", label: "USB Link", value: speed,
                                   verdict: high == true ? .pass : (high == false ? .warn : .info),
                                   note: high == false ? "Expected high speed. Re-seat the adapter; check the cable." : nil))
            }
            if let stable = usb.stable {
                out.append(DiagRow(id: "power.usb.stable", label: "USB Stability", value: stable ? "Stable" : "Dropped out",
                                   verdict: stable ? .pass : .warn,
                                   note: stable ? nil : "Power delivery unstable — suspect the power supply (or the cable)."))
            }
        }
        if let pmu {
            if let node = pmu.node {
                out.append(DiagRow(id: "power.pmu.node", label: "PMU", value: node, verdict: .pass))
            }
            if let flags = pmu.bootFlags {
                out.append(DiagRow(id: "power.pmu.bootFlags", label: "Boot Flags", value: flags, verdict: .info))
            }
            for rail in pmu.rails {
                out.append(DiagRow(id: "power.rail.\(rail.name)", label: rail.name,
                                   value: rail.displayValue, verdict: .info))
            }
        }
        if let r = DiagRow.note(tool: .power, note) { out.append(r) }
        return out
    }
}

// MARK: - SysCfg calibration payloads (hpdiag-audio / hpdiag-radio)

/// One factory-calibration tag as a script found it in SysCfg. The audio
/// script sends the small payloads whole (`hex`) so the Mac can decode them;
/// the radio script sends only the container header of its large blobs.
public struct SysCfgCalibrationBlob: Codable, Sendable, Equatable, Identifiable {
    /// Four-character SysCfg key, e.g. "SpEQ".
    public let tag: String
    public let present: Bool?
    /// Payload size in SysCfg.
    public let bytes: Int?
    /// Size the script expected (audio tags only).
    public let expectedBytes: Int?
    /// Stored inline in the entry table (16 bytes) rather than as a blob.
    public let inline: Bool?
    /// Every byte 0x00 or 0xFF — erased flash, not a calibration.
    public let blank: Bool?
    /// Format version (word 0 of an audio payload, word 3 of a BLOB container).
    public let version: Int?
    /// Audio: how many units the payload holds (tweeters, mics).
    public let units: Int?
    /// Audio: the whole payload, plain hex.
    public let hex: String?
    /// RF: container magic ("BLOB").
    public let magic: String?
    /// RF: container header size; 20 + 20 × sections when well-formed.
    public let headerBytes: Int?
    /// RF: number of sections in the container.
    public let sections: Int?
    /// RF: the container header (section table), plain hex.
    public let header: String?
    /// RF: magic, header size and section count agree with each other.
    public let containerValid: Bool?
    /// Device-tree property iBoot fills from this tag.
    public let dtProperty: String?
    public let dtBytes: Int?
    public let dtZero: Bool?
    /// The device-tree copy is byte-identical to the SysCfg payload.
    public let dtMatches: Bool?

    public var id: String { tag }

    enum CodingKeys: String, CodingKey {
        case tag, present, bytes, expectedBytes, inline, blank, version, units, hex
        case magic, headerBytes, sections, header, containerValid, dtProperty, dtBytes, dtZero, dtMatches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = c.diagString(.tag) ?? "?"
        present = c.diagBool(.present)
        bytes = c.diagInt(.bytes)
        expectedBytes = c.diagInt(.expectedBytes)
        inline = c.diagBool(.inline)
        blank = c.diagBool(.blank)
        version = c.diagInt(.version)
        units = c.diagInt(.units)
        // Decoded as a plain string on purpose: the lenient helper would turn an
        // all-digit hex run into a number.
        hex = ((try? c.decodeIfPresent(String.self, forKey: .hex)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        magic = ((try? c.decodeIfPresent(String.self, forKey: .magic)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        headerBytes = c.diagInt(.headerBytes)
        sections = c.diagInt(.sections)
        header = ((try? c.decodeIfPresent(String.self, forKey: .header)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        containerValid = c.diagBool(.containerValid)
        dtProperty = c.diagString(.dtProperty)
        dtBytes = c.diagInt(.dtBytes)
        dtZero = c.diagBool(.dtZero)
        dtMatches = c.diagBool(.dtMatches)
    }

    /// The payload bytes, when the script sent them.
    public var payload: Data? { hex.flatMap(PuffinUnitCalibration.data(hex:)) }

    /// Present with real content.
    public var isUsable: Bool { present == true && blank != true }

    /// One section of a 'BLOB' container: its type id and where it sits.
    public struct Section: Sendable, Equatable {
        public let type: Int
        public let offset: Int
        public let length: Int
    }

    /// The section table of a 'BLOB' container, from `header`. Layout seen on a
    /// production unit: magic, header bytes, checksum, version, section count,
    /// then per section five words — type, offset, length, stamp, reserved.
    public var sectionTable: [Section] {
        guard let data = header.flatMap(PuffinUnitCalibration.data(hex:)), data.count >= 20, data.count % 4 == 0 else { return [] }
        let b = [UInt8](data)
        func word(_ i: Int) -> Int { Int(b[i * 4]) | Int(b[i * 4 + 1]) << 8 | Int(b[i * 4 + 2]) << 16 | Int(b[i * 4 + 3]) << 24 }
        let count = word(4)
        guard count >= 1, count <= 64, b.count >= 20 + count * 20 else { return [] }
        return (0..<count).map { n in Section(type: word(5 + n * 5), offset: word(6 + n * 5), length: word(7 + n * 5)) }
    }

    /// Every section lies inside the blob, after the header. `nil` when the
    /// header wasn't sent.
    public var sectionsInBounds: Bool? {
        let table = sectionTable
        guard !table.isEmpty, let bytes, let headerBytes else { return nil }
        return table.allSatisfy { $0.offset >= headerBytes && $0.length >= 0 && $0.offset + $0.length <= bytes }
    }
}

// MARK: - Radios (hpdiag-radio)

/// Wi-Fi / Bluetooth presence and identity. An existence check, not an RF test.
public struct RadioStatus: Codable, Sendable, Equatable {
    public struct Radio: Codable, Sendable, Equatable {
        public let present: Bool?
        /// Attached driver class (e.g. "AppleBCMWLANCore").
        public let driver: String?
        public let mac: String?
        /// The radio's MAC equals the one in SysCfg; `nil` when not compared.
        public fileprivate(set) var matchesSysCfg: Bool?

        enum CodingKeys: String, CodingKey { case present, driver, mac, matchesSysCfg }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            present = c.diagBool(.present)
            driver = c.diagString(.driver)
            mac = c.diagString(.mac).flatMap { $0.isEmpty ? nil : $0 }
            matchesSysCfg = c.diagBool(.matchesSysCfg)
        }

        var verdict: DiagVerdict? {
            var parts: [DiagVerdict] = []
            if let present { parts.append(present ? .pass : .fail) }
            if let matchesSysCfg { parts.append(matchesSysCfg ? .pass : .warn) }
            return parts.isEmpty ? nil : DiagVerdict.worst(parts)
        }
    }

    /// The RF calibration blobs in SysCfg. At the factory, DIAGS loads each
    /// unit's own blob into its radio (`wifi --send_cmd calload`, and
    /// `bluetooth --send_raw` in 230-byte chunks); in normal boots iBoot hands
    /// them over through the device tree. A radio without its blob runs
    /// uncalibrated.
    public struct Calibration: Codable, Sendable, Equatable {
        /// `WCAL`.
        public let wifi: SysCfgCalibrationBlob?
        /// `BCAL`.
        public let bt: SysCfgCalibrationBlob?

        enum CodingKeys: String, CodingKey { case wifi, bt }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            wifi = (try? c.decodeIfPresent(SysCfgCalibrationBlob.self, forKey: .wifi)) ?? nil
            bt = (try? c.decodeIfPresent(SysCfgCalibrationBlob.self, forKey: .bt)) ?? nil
        }

        /// Sections the factory Bluetooth loader sends (`gBTSections`).
        public static let bluetoothSections = 3
        /// Chunk size the factory Bluetooth loader uses (`gBTChunkSize`).
        public static let bluetoothChunkBytes = 230

        /// HCI chunks the factory loader would send for a BCAL of this size.
        public static func bluetoothChunks(forBytes bytes: Int) -> Int {
            bytes <= 0 ? 0 : (bytes + bluetoothChunkBytes - 1) / bluetoothChunkBytes
        }

        static func verdict(for blob: SysCfgCalibrationBlob?) -> DiagVerdict? {
            guard let blob, let present = blob.present else { return nil }
            if !present || blob.blank == true || blob.containerValid == false || blob.sectionsInBounds == false { return .warn }
            return .pass
        }
    }

    public let ok: Bool
    public private(set) var wifi: Radio?
    public private(set) var bt: Radio?
    public let calibration: Calibration?
    public let note: String?
    public let error: String?
    public private(set) var verdict: DiagVerdict
    /// What the script itself reported, kept so the verdict can be re-derived.
    private let reportedVerdict: DiagVerdict?

    enum CodingKeys: String, CodingKey {
        case ok, wifi, bt, calibration, note, error, verdict, reportedVerdict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.diagBool(.ok) ?? true
        wifi = (try? c.decodeIfPresent(Radio.self, forKey: .wifi)) ?? nil
        bt = (try? c.decodeIfPresent(Radio.self, forKey: .bt)) ?? nil
        calibration = (try? c.decodeIfPresent(Calibration.self, forKey: .calibration)) ?? nil
        note = c.diagString(.note)
        error = c.diagString(.error)
        let decodedVerdict = c.diagVerdict(.verdict)
        // A re-decoded export carries the script's own verdict separately.
        reportedVerdict = c.contains(.reportedVerdict) ? c.diagVerdict(.reportedVerdict) : decodedVerdict
        verdict = .info
        verdict = resolvedVerdict(floor: decodedVerdict)
    }

    private func resolvedVerdict(floor: DiagVerdict? = nil) -> DiagVerdict {
        let parts = [wifi?.verdict, bt?.verdict,
                     Calibration.verdict(for: calibration?.wifi), Calibration.verdict(for: calibration?.bt)].compactMap { $0 }
        let derived = parts.isEmpty ? nil : DiagVerdict.worst(parts)
        let reported = [reportedVerdict, floor].compactMap { $0 }
        return DiagVerdict.resolve(ok: ok, reported: reported.isEmpty ? nil : DiagVerdict.worst(reported), derived: derived)
    }

    /// Fills in `matchesSysCfg` Mac-side when the script didn't compare, using
    /// the MACs from a SysCfg read. A SysCfg MAC that isn't a full six bytes
    /// (the display parser stops at a NUL byte) is ignored rather than risk a
    /// false mismatch.
    public func crossChecked(wifiMAC: String?, bluetoothMAC: String?) -> RadioStatus {
        var copy = self
        copy.wifi = Self.fill(copy.wifi, reference: wifiMAC)
        copy.bt = Self.fill(copy.bt, reference: bluetoothMAC)
        copy.verdict = copy.resolvedVerdict()
        return copy
    }

    private static func fill(_ radio: Radio?, reference: String?) -> Radio? {
        guard var radio, radio.matchesSysCfg == nil,
              let mine = radio.mac.flatMap(DiagFormat.normalizedMAC),
              let theirs = reference.flatMap(DiagFormat.normalizedMAC) else { return radio }
        radio.matchesSysCfg = mine == theirs
        return radio
    }

    public var rows: [DiagRow] {
        var out: [DiagRow] = []
        if let r = DiagRow.status(tool: .radio, ok: ok, error: error) { out.append(r) }
        out += Self.rows(for: wifi, key: "wifi", name: "Wi-Fi")
        out += Self.rows(for: bt, key: "bt", name: "Bluetooth")
        if let r = Self.calibrationRow(calibration?.wifi, key: "wifi", name: "Wi-Fi") { out.append(r) }
        if let r = Self.calibrationRow(calibration?.bt, key: "bt", name: "Bluetooth") { out.append(r) }
        if let r = DiagRow.note(tool: .radio, note) { out.append(r) }
        return out
    }

    /// "Wi-Fi Calibration: WCAL · 1792 bytes · 6 sections".
    static func calibrationRow(_ blob: SysCfgCalibrationBlob?, key: String, name: String) -> DiagRow? {
        guard let blob, let present = blob.present else { return nil }
        let id = "radio.\(key).calibration"
        let label = "\(name) Calibration"
        guard present else {
            return DiagRow(id: id, label: label, value: "\(blob.tag) missing", verdict: .warn,
                           note: "This unit's \(name) calibration isn't in SysCfg, so the radio runs uncalibrated (weak range, or a driver that won't start). Typical after a NAND swap without the unit's own SysCfg.")
        }
        if blob.blank == true {
            return DiagRow(id: id, label: label, value: "\(blob.tag) is blank", verdict: .warn,
                           note: "The key exists but holds erased flash — there is no calibration in it.")
        }
        var parts = [blob.tag]
        if let bytes = blob.bytes { parts.append("\(bytes) bytes") }
        if let sections = blob.sections { parts.append("\(sections) section\(sections == 1 ? "" : "s")") }
        let value = parts.joined(separator: " · ")
        if blob.containerValid == false || blob.sectionsInBounds == false {
            return DiagRow(id: id, label: label, value: value, verdict: .warn,
                           note: "The data doesn't have the calibration container's structure (\"BLOB\" header with a consistent section table). It was probably written incorrectly or truncated.")
        }
        var notes: [String] = []
        if blob.dtMatches == true { notes.append("iBoot passed the same bytes to the driver.") }
        else if blob.dtMatches == false { notes.append("The copy iBoot passed to the driver isn't byte-identical — informational, not yet judged.") }
        if key == "bt", let sections = blob.sections, sections != Calibration.bluetoothSections {
            notes.append("The factory loader expects \(Calibration.bluetoothSections) sections.")
        }
        return DiagRow(id: id, label: label, value: value, verdict: .pass, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func rows(for radio: Radio?, key: String, name: String) -> [DiagRow] {
        guard let radio else { return [] }
        var out: [DiagRow] = []
        if let present = radio.present {
            out.append(DiagRow(id: "radio.\(key).present", label: "\(name) Radio", value: present ? "Detected" : "Not detected",
                               verdict: present ? .pass : .fail,
                               note: present ? radio.driver.map { "Driver: \($0)" }
                                             : "The controller didn't enumerate — suspect the radio module or the board."))
        }
        if let mac = radio.mac {
            let match = radio.matchesSysCfg
            out.append(DiagRow(id: "radio.\(key).mac", label: "\(name) MAC", value: mac,
                               verdict: match == true ? .pass : (match == false ? .warn : .info),
                               note: match == true ? "Matches SysCfg."
                                    : (match == false ? "Doesn't match SysCfg — wrong or unprovisioned part, or the wrong SysCfg."
                                                      : "Not compared against SysCfg.")))
        }
        return out
    }
}

// MARK: - Audio (hpdiag-audio)

/// Audio hardware enumeration. NOT an audible test — the ramdisk can't play sound.
public struct AudioStatus: Codable, Sendable, Equatable {
    public struct Channel: Codable, Sendable, Equatable, Identifiable {
        /// Channel name, e.g. "tweeter0" or "woofer".
        public let ch: String
        /// Amp fault status: "none", "open-load", "short", "over-temp"…
        public let fault: String?

        public var id: String { ch }

        enum CodingKeys: String, CodingKey { case ch, fault }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ch = c.diagString(.ch) ?? "channel"
            fault = c.diagString(.fault)
        }

        /// The amp reports a real fault on this channel.
        public var hasFault: Bool {
            guard let f = fault?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
            return !["", "none", "ok", "no", "0", "false"].contains(f)
        }
    }

    /// One block of the audio chain, named the way Apple's factory reset
    /// scripts address it (`audio -b <block>`): socmca, ampcontroller, codec0…
    public struct Block: Codable, Sendable, Equatable, Identifiable {
        /// Factory block name.
        public let block: String
        /// What the block does, in plain words.
        public let role: String?
        /// The chain can't work without it (as opposed to "nice to see").
        public let required: Bool
        /// A node for it enumerated in the IORegistry.
        public let found: Bool?
        public let nodes: Int?
        public let driversAttached: Int?
        /// IORegistry node names that matched.
        public let names: [String]

        public var id: String { block }

        enum CodingKeys: String, CodingKey { case block, role, required, found, nodes, driversAttached, names }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            block = c.diagString(.block) ?? "?"
            role = c.diagString(.role)
            required = c.diagBool(.required) ?? false
            found = c.diagBool(.found)
            nodes = c.diagInt(.nodes)
            driversAttached = c.diagInt(.driversAttached)
            names = c.diagStrings(.names)
        }

        /// Which assembly to look at when this block doesn't answer.
        public var suspect: String {
            switch block {
            case "ampcontroller", "amp-data": return "the amp board or its flex"
            case "codec0", "codec1", "codec2": return "the microphone array / top assembly"
            case "socmca", "i2s-switch": return "the logic board"
            default: return "its connection"
            }
        }
    }

    public let ok: Bool
    public let codecDetected: Bool?
    /// Amp nodes that enumerated in the IORegistry.
    public let ampNodes: [String]
    /// Per-channel fault status (only when the amp fault registers are readable).
    public let amps: [Channel]
    /// A tone was actually played. Always false today.
    public let audibleTest: Bool
    /// The factory audio chain, block by block (presence only).
    public let topology: [Block]
    /// The audio calibration tags in SysCfg: SpEQ, WFEQ, MiGa, SpGa.
    public let calibration: [SysCfgCalibrationBlob]
    /// IORegistry class the calibration was read from.
    public let calibrationSource: String?
    public let note: String?
    public let error: String?
    public let verdict: DiagVerdict

    enum CodingKeys: String, CodingKey {
        case ok, codecDetected, ampNodes, amps, audibleTest, topology, calibration, calibrationSource, note, error, verdict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.diagBool(.ok) ?? true
        codecDetected = c.diagBool(.codecDetected)
        ampNodes = c.diagStrings(.ampNodes)
        amps = c.diagArray(.amps)
        audibleTest = c.diagBool(.audibleTest) ?? false
        topology = c.diagArray(.topology)
        calibration = c.diagArray(.calibration)
        calibrationSource = c.diagString(.calibrationSource)
        note = c.diagString(.note)
        error = c.diagString(.error)

        var parts: [DiagVerdict] = []
        if let codecDetected { parts.append(codecDetected ? .pass : .fail) }
        if !amps.isEmpty { parts.append(amps.contains(where: \.hasFault) ? .warn : .pass) }
        if !calibration.isEmpty { parts.append(calibration.allSatisfy(\.isUsable) ? .pass : .warn) }
        verdict = DiagVerdict.resolve(ok: ok, reported: c.diagVerdict(.verdict),
                                      derived: parts.isEmpty ? nil : DiagVerdict.worst(parts))
    }

    /// Channels whose amp reports a fault.
    public var faultedChannels: [Channel] { amps.filter(\.hasFault) }

    /// Required factory blocks that didn't enumerate.
    public var missingBlocks: [Block] { topology.filter { $0.required && $0.found == false } }

    /// Calibration tags that are absent or blank.
    public var unusableCalibration: [SysCfgCalibrationBlob] { calibration.filter { !$0.isUsable } }

    /// The unit's audio calibration, decoded from the payloads the script sent.
    /// `nil` when the script sent none (older revision, or SysCfg unreadable).
    public var unitCalibration: PuffinUnitCalibration? {
        var payloads: [PuffinCalibrationTag: Data] = [:]
        for blob in calibration where blob.isUsable {
            guard let tag = PuffinCalibrationTag(rawValue: blob.tag), let data = blob.payload else { continue }
            payloads[tag] = data
        }
        return payloads.isEmpty ? nil : PuffinUnitCalibration(payloads: payloads)
    }

    public var rows: [DiagRow] {
        var out: [DiagRow] = []
        if let r = DiagRow.status(tool: .audio, ok: ok, error: error) { out.append(r) }
        if let codecDetected {
            out.append(DiagRow(id: "audio.codec", label: "Audio Codec", value: codecDetected ? "Detected" : "Not detected",
                               verdict: codecDetected ? .pass : .fail,
                               note: codecDetected ? nil : "The codec didn't enumerate — dead codec or an unseated flex."))
        }
        if !ampNodes.isEmpty {
            out.append(DiagRow(id: "audio.ampNodes", label: "Amp Nodes", value: String(ampNodes.count), verdict: .pass,
                               note: ampNodes.joined(separator: ", ")))
        }
        for a in amps {
            out.append(DiagRow(id: "audio.amp.\(a.ch)", label: a.ch, value: a.hasFault ? (a.fault ?? "fault") : "No fault",
                               verdict: a.hasFault ? .warn : .pass,
                               note: a.hasFault ? "The amp reports a load fault on this driver — check the coil and its connector." : nil))
        }
        // The factory chain. Never judged: whether this ramdisk attaches every
        // audio node on a healthy pod hasn't been confirmed, so a missing block
        // is a lead to follow, not a verdict.
        let required = topology.filter(\.required)
        if !required.isEmpty, required.contains(where: { $0.found == true }) {
            let missing = missingBlocks
            let found = required.count - missing.count
            if missing.isEmpty {
                out.append(DiagRow(id: "audio.chain", label: "Audio Chain", value: "\(found) of \(required.count) blocks answer", verdict: .info,
                                   note: "SoC I2S ports, amp controller and both mic codecs all enumerate — the blocks Apple's factory audio reset addresses."))
            } else {
                let leads = missing.map { "\($0.block) → \($0.suspect)" }.joined(separator: "; ")
                out.append(DiagRow(id: "audio.chain", label: "Audio Chain", value: "\(found) of \(required.count) blocks answer", verdict: .info,
                                   note: "Not seen: \(leads). Other audio blocks did enumerate, so compare with a known-good pod on the same ramdisk before condemning the part."))
            }
        }
        if !calibration.isEmpty {
            let bad = unusableCalibration
            if bad.isEmpty {
                out.append(DiagRow(id: "audio.tuning", label: "Factory Tuning", value: "Present (\(calibration.map(\.tag).joined(separator: ", ")))", verdict: .pass))
            } else {
                let list = bad.map { $0.present == true ? "\($0.tag) blank" : "\($0.tag) missing" }.joined(separator: ", ")
                out.append(DiagRow(id: "audio.tuning", label: "Factory Tuning", value: list, verdict: .warn,
                                   note: "The unit will play, but without the acoustic calibration measured for these exact drivers. See Factory Calibration below."))
            }
        }
        if ok {
            out.append(DiagRow(id: "audio.audibleTest", label: "Audible Test", value: audibleTest ? "Tone played" : "Not performed",
                               verdict: .info,
                               note: audibleTest ? nil : "Hardware detection only — the ramdisk can't play sound, so this doesn't prove the speakers work."))
        }
        if let r = DiagRow.note(tool: .audio, note) { out.append(r) }
        return out
    }
}

// MARK: - Sensor presence (hpdiag-mic + hpdiag-accel)

/// Presence of the AOP-side sensors. Presence only — the restore ramdisk doesn't
/// boot the AOP, so neither the mic array nor the tap sensor can be exercised.
public struct SensorPresence: Codable, Sendable, Equatable {
    public let ok: Bool
    public let micDetected: Bool?
    public let accelDetected: Bool?
    /// AOP IORegistry node the sensors hang off.
    public let aopNode: String?
    /// A real mic capture ran. Always false today.
    public let micCapture: Bool?
    /// Live accelerometer samples were read. Always false today.
    public let accelLiveSampling: Bool?
    public let note: String?
    public let error: String?
    public let verdict: DiagVerdict

    enum CodingKeys: String, CodingKey {
        case ok, micDetected, accelDetected, aopNode, micCapture, accelLiveSampling, note, error, verdict
    }

    /// Keys of the per-tool objects (`hpdiag-mic` / `hpdiag-accel`) and of a
    /// nested `{"mic":{…},"accel":{…}}` form.
    private enum WireKeys: String, CodingKey {
        case tool, detected, capture, liveSampling, mic, accel
    }

    private struct Part: Decodable {
        let detected: Bool?
        let capture: Bool?
        let liveSampling: Bool?
        let aopNode: String?

        enum CodingKeys: String, CodingKey { case detected, capture, liveSampling, aopNode }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            detected = c.diagBool(.detected)
            capture = c.diagBool(.capture)
            liveSampling = c.diagBool(.liveSampling)
            aopNode = c.diagString(.aopNode)
        }
    }

    /// Accepts three shapes: the combined object (this type's own keys), the
    /// per-tool object (`"tool":"mic"` / `"accel"` with `detected`), and a
    /// nested `mic` / `accel` pair.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = try decoder.container(keyedBy: WireKeys.self)
        let tool = w.diagString(.tool)?.lowercased()
        let micPart = (try? w.decodeIfPresent(Part.self, forKey: .mic)) ?? nil
        let accelPart = (try? w.decodeIfPresent(Part.self, forKey: .accel)) ?? nil
        let detected = w.diagBool(.detected)

        ok = c.diagBool(.ok) ?? true
        micDetected = c.diagBool(.micDetected) ?? micPart?.detected ?? (tool == "mic" ? detected : nil)
        accelDetected = c.diagBool(.accelDetected) ?? accelPart?.detected ?? (tool == "accel" ? detected : nil)
        aopNode = c.diagString(.aopNode) ?? micPart?.aopNode ?? accelPart?.aopNode
        micCapture = c.diagBool(.micCapture) ?? micPart?.capture ?? w.diagBool(.capture)
        accelLiveSampling = c.diagBool(.accelLiveSampling) ?? accelPart?.liveSampling ?? w.diagBool(.liveSampling)
        note = c.diagString(.note)
        error = c.diagString(.error)
        verdict = DiagVerdict.resolve(ok: ok, reported: c.diagVerdict(.verdict),
                                      derived: Self.derive(mic: micDetected, accel: accelDetected))
    }

    private init(ok: Bool, micDetected: Bool?, accelDetected: Bool?, aopNode: String?, micCapture: Bool?,
                 accelLiveSampling: Bool?, note: String?, error: String?, verdict: DiagVerdict) {
        self.ok = ok
        self.micDetected = micDetected
        self.accelDetected = accelDetected
        self.aopNode = aopNode
        self.micCapture = micCapture
        self.accelLiveSampling = accelLiveSampling
        self.note = note
        self.error = error
        self.verdict = verdict
    }

    /// A missing sensor is a warning, not a failure: in the restore ramdisk an
    /// absent node can also mean the AOP personality simply didn't attach.
    static func derive(mic: Bool?, accel: Bool?) -> DiagVerdict? {
        let parts = [mic, accel].compactMap { $0 }.map { $0 ? DiagVerdict.info : DiagVerdict.warn }
        return parts.isEmpty ? nil : DiagVerdict.worst(parts)
    }

    /// Combines the mic and accel halves into one result.
    public func merging(_ other: SensorPresence) -> SensorPresence {
        func join(_ a: String?, _ b: String?) -> String? {
            let parts = [a, b].compactMap { $0 }.filter { !$0.isEmpty }
            guard let first = parts.first else { return nil }
            return parts.count == 2 && parts[0] != parts[1] ? parts.joined(separator: " · ") : first
        }
        return SensorPresence(ok: ok || other.ok,
                              micDetected: micDetected ?? other.micDetected,
                              accelDetected: accelDetected ?? other.accelDetected,
                              aopNode: aopNode ?? other.aopNode,
                              micCapture: micCapture ?? other.micCapture,
                              accelLiveSampling: accelLiveSampling ?? other.accelLiveSampling,
                              note: join(note, other.note),
                              error: join(error, other.error),
                              verdict: DiagVerdict.worst([verdict, other.verdict]))
    }

    public var rows: [DiagRow] {
        var out: [DiagRow] = []
        if let r = DiagRow.status(tool: .mic, ok: ok, error: error, id: "sensors.status", label: "Sensors") { out.append(r) }
        if let mic = micDetected {
            out.append(DiagRow(id: "sensors.mic", label: "Microphone Board", value: mic ? "Detected" : "Not detected",
                               verdict: mic ? .info : .warn,
                               note: mic ? (micCapture == true ? nil : "Presence only — the mics aren't captured from the ramdisk, so this isn't a working-mic test.")
                                         : "No mic node found. Check the mic board flex (the ramdisk may also simply not attach it)."))
        }
        if let accel = accelDetected {
            out.append(DiagRow(id: "sensors.accel", label: "Tap Sensor", value: accel ? "Detected" : "Not detected",
                               verdict: accel ? .info : .warn,
                               note: accel ? (accelLiveSampling == true ? nil : "Presence only — no live samples are read from the ramdisk.")
                                           : "No accelerometer node found (the ramdisk may also simply not attach it)."))
        }
        if let aopNode {
            out.append(DiagRow(id: "sensors.aop", label: "AOP Node", value: aopNode, verdict: .info))
        }
        if let r = DiagRow.note(tool: .mic, note, id: "sensors.note") { out.append(r) }
        return out
    }
}

// MARK: - Tool result wrapper

/// A tool that produced no usable result (script missing, SSH error, bad JSON).
public struct DiagToolFailure: Codable, Sendable, Equatable {
    public let tool: DiagTool
    /// Plain-words reason, shown to the tech.
    public let message: String
    /// Tail of what the pod printed, for the JSON export / support.
    public let rawOutput: String?

    public init(tool: DiagTool, message: String, rawOutput: String? = nil) {
        self.tool = tool
        self.message = message
        self.rawOutput = rawOutput
    }
}

/// One tool's outcome. Encodes flat, the way the scripts print it:
/// `{"tool":"nand", …fields…}`.
public enum DiagToolResult: Sendable, Equatable, Identifiable {
    case nand(NANDHealth)
    case partmap(PartitionMap)
    case factory(FactoryData)
    case thermal(ThermalSnapshot)
    case power(PowerStatus)
    case radio(RadioStatus)
    case audio(AudioStatus)
    case sensors(SensorPresence)
    /// The tool couldn't run or its output couldn't be read.
    case failed(DiagToolFailure)

    /// Wire name: the script's `tool` value ("sensors" for the merged mic+accel).
    public var name: String {
        switch self {
        case .nand: return "nand"
        case .partmap: return "partmap"
        case .factory: return "factory"
        case .thermal: return "thermal"
        case .power: return "power"
        case .radio: return "radio"
        case .audio: return "audio"
        case .sensors: return "sensors"
        case .failed(let f): return f.tool.rawValue
        }
    }

    public var id: String { name }

    public var title: String {
        switch self {
        case .nand: return DiagTool.nand.title
        case .partmap: return DiagTool.partmap.title
        case .factory: return DiagTool.factory.title
        case .thermal: return DiagTool.thermal.title
        case .power: return DiagTool.power.title
        case .radio: return DiagTool.radio.title
        case .audio: return DiagTool.audio.title
        case .sensors: return "Sensors"
        case .failed(let f): return f.tool.title
        }
    }

    public var subsystem: DiagSubsystem {
        switch self {
        case .nand, .partmap: return .storage
        case .factory: return .factory
        case .thermal, .power, .radio: return .environment
        case .audio: return .audio
        case .sensors: return .sensors
        case .failed(let f): return f.tool.subsystem
        }
    }

    public var verdict: DiagVerdict {
        switch self {
        case .nand(let r): return r.verdict
        case .partmap(let r): return r.verdict
        case .factory(let r): return r.verdict
        case .thermal(let r): return r.verdict
        case .power(let r): return r.verdict
        case .radio(let r): return r.verdict
        case .audio(let r): return r.verdict
        case .sensors(let r): return r.verdict
        // "Couldn't check" is not a verdict on the hardware.
        case .failed: return .info
        }
    }

    /// False when the tool didn't produce a result (or said it couldn't run).
    public var completed: Bool {
        switch self {
        case .nand(let r): return r.ok
        case .partmap(let r): return r.ok
        case .factory(let r): return r.ok
        case .thermal(let r): return r.ok
        case .power(let r): return r.ok
        case .radio(let r): return r.ok
        case .audio(let r): return r.ok
        case .sensors(let r): return r.ok
        case .failed: return false
        }
    }

    /// Display rows. When the tool's verdict is worse than every row it
    /// produced (the script judged something we have no row for), a summary
    /// row is put first so a red banner always has a red row explaining it.
    public var rows: [DiagRow] {
        let rows = detailRows
        let verdict = self.verdict
        guard verdict == .warn || verdict == .fail,
              !rows.contains(where: { $0.verdict.severity >= verdict.severity }) else { return rows }
        let summary = DiagRow(id: "\(name).verdict", label: title,
                              value: verdict == .fail ? "Failed" : "Needs attention", verdict: verdict,
                              note: note ?? "The pod-side check flagged this.")
        return [summary] + rows.filter { $0.id != "\(name).note" }
    }

    /// The script's free-text note, if any.
    public var note: String? {
        switch self {
        case .nand(let r): return r.note
        case .partmap(let r): return r.note
        case .factory(let r): return r.note
        case .thermal(let r): return r.note
        case .power(let r): return r.note
        case .radio(let r): return r.note
        case .audio(let r): return r.note
        case .sensors(let r): return r.note
        case .failed: return nil
        }
    }

    private var detailRows: [DiagRow] {
        switch self {
        case .nand(let r): return r.rows
        case .partmap(let r): return r.rows
        case .factory(let r): return r.rows
        case .thermal(let r): return r.rows
        case .power(let r): return r.rows
        case .radio(let r): return r.rows
        case .audio(let r): return r.rows
        case .sensors(let r): return r.rows
        case .failed(let f):
            return [DiagRow(id: "\(f.tool.rawValue).status", label: f.tool.title, value: "Couldn't check",
                            verdict: .info, note: f.message)]
        }
    }
}

extension DiagToolResult: Codable {
    private enum Keys: String, CodingKey { case tool, failed, error, rawOutput }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let name = (c.diagString(.tool) ?? "").lowercased()
        if c.diagBool(.failed) == true, let tool = DiagTool(rawValue: name) {
            self = .failed(DiagToolFailure(tool: tool, message: c.diagString(.error) ?? "No result.",
                                           rawOutput: c.diagString(.rawOutput)))
            return
        }
        switch name {
        case "nand": self = .nand(try NANDHealth(from: decoder))
        case "partmap": self = .partmap(try PartitionMap(from: decoder))
        case "factory": self = .factory(try FactoryData(from: decoder))
        case "thermal": self = .thermal(try ThermalSnapshot(from: decoder))
        case "power": self = .power(try PowerStatus(from: decoder))
        case "radio": self = .radio(try RadioStatus(from: decoder))
        case "audio": self = .audio(try AudioStatus(from: decoder))
        case "mic", "accel", "sensors": self = .sensors(try SensorPresence(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .tool, in: c,
                                                   debugDescription: "Unknown diagnostic tool \"\(name)\".")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .tool)
        switch self {
        case .nand(let r): try r.encode(to: encoder)
        case .partmap(let r): try r.encode(to: encoder)
        case .factory(let r): try r.encode(to: encoder)
        case .thermal(let r): try r.encode(to: encoder)
        case .power(let r): try r.encode(to: encoder)
        case .radio(let r): try r.encode(to: encoder)
        case .audio(let r): try r.encode(to: encoder)
        case .sensors(let r): try r.encode(to: encoder)
        case .failed(let f):
            try c.encode(true, forKey: .failed)
            try c.encode(f.message, forKey: .error)
            try c.encodeIfPresent(f.rawOutput, forKey: .rawOutput)
        }
    }
}

// MARK: - Full report

/// Everything one "Run full diagnostics" pass found, keyed to the unit.
public struct FullDiagnosticsReport: Sendable, Equatable {
    /// The unit's serial number, when it could be read.
    public let serial: String?
    /// When the run finished (Mac clock — the ramdisk's clock isn't trustworthy).
    public let timestamp: Date
    public let results: [DiagToolResult]
    /// Worst verdict across the tools that reached one.
    public let overall: DiagVerdict

    public init(serial: String?, timestamp: Date = Date(), results: [DiagToolResult]) {
        self.serial = serial
        self.timestamp = timestamp
        self.results = results
        self.overall = Self.overallVerdict(results)
    }

    /// Worst of the pass/warn/fail verdicts. `.info` when nothing conclusive
    /// came back — informational results and tools that couldn't run don't count.
    public static func overallVerdict(_ results: [DiagToolResult]) -> DiagVerdict {
        DiagVerdict.worst(results.map(\.verdict).filter { $0 != .info })
    }

    /// Results belonging to one UI group, in run order.
    public func results(in subsystem: DiagSubsystem) -> [DiagToolResult] {
        results.filter { $0.subsystem == subsystem }
    }

    /// Display rows for one UI group.
    public func rows(in subsystem: DiagSubsystem) -> [DiagRow] {
        results(in: subsystem).flatMap(\.rows)
    }

    /// Worst verdict within one UI group.
    public func verdict(in subsystem: DiagSubsystem) -> DiagVerdict {
        Self.overallVerdict(results(in: subsystem))
    }

    /// Tools that didn't produce a result.
    public var incomplete: [DiagToolResult] { results.filter { !$0.completed } }

    /// Every row at warn or fail, worst first — the "what's wrong" short list.
    public var findings: [DiagRow] {
        results.flatMap(\.rows)
            .filter { $0.verdict == .warn || $0.verdict == .fail }
            .sorted { $0.verdict.severity > $1.verdict.severity }
    }

    /// One-line summary for the banner.
    public var headline: String {
        switch overall {
        case .pass:
            return incomplete.isEmpty ? "No problems found" : "No problems found in the checks that ran"
        case .warn: return "Needs a closer look"
        case .fail: return "Problems found"
        case .info: return "Nothing conclusive — the checks couldn't run or only reported presence"
        }
    }

    /// Pretty-printed JSON for "Export JSON".
    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Suggested base file name: `homepod-diag-<serial>-<timestamp>`.
    public var suggestedFileName: String {
        let stamp = DiagFormat.iso8601(timestamp).replacingOccurrences(of: ":", with: "-")
        return "homepod-diag-\(serial ?? "unknown")-\(stamp)"
    }

    /// Plain-text summary for pasting into a support chat. Identifiers are
    /// shortened by default (serial to its last four characters, MAC addresses
    /// to their vendor prefix) so the text is safe to post publicly.
    public func supportText(appVersion: String? = nil, redactIdentifiers: Bool = true) -> String {
        var lines: [String] = ["HomePod diagnostics report"]
        if let appVersion { lines.append("App: \(appVersion)") }
        let shownSerial = serial.map { redactIdentifiers ? DiagFormat.redactedSerial($0) : $0 } ?? "unknown"
        lines.append("Serial: \(shownSerial)")
        lines.append("Run: \(DiagFormat.iso8601(timestamp))")
        lines.append("Overall: \(overall.tag) — \(headline)")
        for subsystem in DiagSubsystem.allCases {
            let rows = rows(in: subsystem)
            guard !rows.isEmpty else { continue }
            lines.append("")
            lines.append("[\(subsystem.title)]")
            for row in rows {
                var value = row.value
                if redactIdentifiers, row.id.hasSuffix(".mac") { value = DiagFormat.redactedMAC(value) }
                if redactIdentifiers, row.id.hasSuffix(".uid") { value = NANDHealth.redactedUniqueId(value) }
                lines.append("  \(row.verdict.tag.padding(toLength: 4, withPad: " ", startingAt: 0))  \(row.label): \(value)")
                if let note = row.note, row.verdict != .pass { lines.append("        \(note)") }
            }
        }
        if let calibration = factoryCalibration {
            lines.append("")
            lines.append("[\(FactoryCalibrationReport.title)]")
            for row in calibration.rows {
                lines.append("  \(row.verdict.tag.padding(toLength: 4, withPad: " ", startingAt: 0))  \(row.label): \(row.value)")
                if let note = row.note, row.verdict != .pass { lines.append("        \(note)") }
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension FullDiagnosticsReport: Codable {
    // "tools" matches the `hpdiag-full` document, so the same type reads both
    // the pod's one-shot output and our own export.
    enum CodingKeys: String, CodingKey { case serial, timestamp, tools, overall }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let serial = c.diagString(.serial).flatMap { $0.isEmpty ? nil : $0 }
        var stamp: Date?
        if let text = try? c.decodeIfPresent(String.self, forKey: .timestamp) {
            stamp = DiagFormat.date(fromISO8601: text)
        } else if let seconds = c.diagDouble(.timestamp), seconds > 0 {
            stamp = Date(timeIntervalSince1970: seconds)
        }
        let results: [DiagToolResult] = c.diagArray(.tools)
        self.init(serial: serial, timestamp: stamp ?? Date(), results: FullDiagnosticsReport.mergingSensors(results))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(serial, forKey: .serial)
        try c.encode(DiagFormat.iso8601(timestamp), forKey: .timestamp)
        try c.encode(results, forKey: .tools)
        try c.encode(overall, forKey: .overall)
    }

    /// Folds separate mic / accel results into a single `.sensors` entry, kept
    /// at the position of the first one.
    public static func mergingSensors(_ results: [DiagToolResult]) -> [DiagToolResult] {
        var out: [DiagToolResult] = []
        var sensorIndex: Int?
        for r in results {
            if case .sensors(let s) = r {
                if let i = sensorIndex, case .sensors(let existing) = out[i] {
                    out[i] = .sensors(existing.merging(s))
                } else {
                    sensorIndex = out.count
                    out.append(r)
                }
            } else {
                out.append(r)
            }
        }
        return out
    }
}

// MARK: - Factory calibration awareness
//
// What a factory-calibrated HomePod SHOULD carry, and how one unit compares.
//
// The expectation comes from two places that agree with each other:
// - Apple's "Puffin" audio-driver templates (see PuffinCalibration.swift): one
//   woofer trim box with 3 EQ bands, seven tweeter trim boxes with 5 bands
//   each, one internal-mic trim and six far-field-mic trims.
// - A production unit's SysCfg, where SpEQ / WFEQ / MiGa have exactly the
//   sizes that layout predicts.
//
// This is deliberately NOT folded into the tools' own verdicts or the report's
// overall verdict: `hpdiag-factory` already warns when a calibration tag is
// missing, and counting the same fact twice would only make the banner
// noisier. The comparison is its own section with its own verdict.

/// The reference a unit's factory calibration is compared against.
public enum FactoryCalibrationExpectation {
    public enum Group: String, Sendable, CaseIterable {
        case audio, radio, led, config

        public var title: String {
            switch self {
            case .audio: return "Audio"
            case .radio: return "Radio"
            case .led: return "LED & Light Sensor"
            case .config: return "Configuration"
            }
        }
    }

    /// One calibration key a factory unit has in SysCfg.
    public struct Key: Sendable, Equatable, Identifiable {
        /// Four-character SysCfg key.
        public let tag: String
        public let title: String
        public let group: Group
        /// Exact payload size when the layout fixes it; `nil` when it varies.
        public let expectedBytes: Int?
        /// What the payload holds.
        public let structure: String
        /// What goes wrong for the customer when it is missing.
        public let consequence: String

        public var id: String { tag }
    }

    public static let wooferCount = 1
    public static let tweeterCount = PuffinSpeakerCalibrationTemplate.tweeterCount
    /// Drivers with their own calibration: one woofer + seven tweeters.
    public static let driverCount = wooferCount + tweeterCount
    public static let wooferBands = PuffinSpeakerCalibrationTemplate.wooferFilters.count
    public static let tweeterBands = PuffinSpeakerCalibrationTemplate.tweeterFilters.count
    public static let internalMicCount = 1
    public static let farFieldMicCount = PuffinMicCalibrationTemplate.farFieldCount
    /// Mic trim boxes in the DSP: one internal + six far-field.
    public static let micCount = internalMicCount + farFieldMicCount
    /// Mic trims actually stored in SysCfg (MiGa): the far-field ones.
    public static let storedMicTrims = farFieldMicCount

    private static func audio(_ tag: PuffinCalibrationTag, _ structure: String) -> Key {
        Key(tag: tag.rawValue, title: tag.title, group: .audio, expectedBytes: tag.expectedBytes,
            structure: structure, consequence: tag.consequence)
    }

    public static let keys: [Key] = [
        audio(.speakerEQ, "7 tweeters × (overall gain + 5 EQ bands)"),
        audio(.wooferEQ, "Woofer: overall gain + 3 EQ bands"),
        audio(.speakerGain, "One speaker gain value"),
        audio(.micGain, "6 far-field microphone trims"),
        Key(tag: "WCAL", title: "Wi-Fi Calibration", group: .radio, expectedBytes: nil,
            structure: "\"BLOB\" container of RF calibration sections (6 on the reference unit)",
            consequence: "Wi-Fi runs uncalibrated — weak or unstable range, or the driver refuses to start."),
        Key(tag: "BCAL", title: "Bluetooth Calibration", group: .radio, expectedBytes: nil,
            structure: "\"BLOB\" container of 3 sections, loaded into the chip in 230-byte chunks",
            consequence: "Bluetooth runs uncalibrated — setup with an iPhone and AirPlay hand-off get unreliable."),
        Key(tag: "LEDc", title: "LED Calibration", group: .led, expectedBytes: nil,
            structure: "Per-LED colour / brightness correction",
            consequence: "The top display's colours and brightness aren't matched across LEDs."),
        Key(tag: "LSCI", title: "Light Sensor Calibration", group: .led, expectedBytes: nil,
            structure: "Ambient light sensor calibration",
            consequence: "Automatic LED brightness is off."),
        Key(tag: "MdlC", title: "Model Configuration", group: .config, expectedBytes: nil,
            structure: "Model configuration string",
            consequence: "The unit's model configuration record is missing."),
    ]

    public static func key(_ tag: String) -> Key? { keys.first { $0.tag == tag } }

    /// One-line statement of the expected audio layout.
    public static let layoutSummary =
        "\(driverCount) drivers (\(wooferCount) woofer with \(wooferBands) EQ bands + \(tweeterCount) tweeters with \(tweeterBands) each) and \(micCount) microphones (\(internalMicCount) internal + \(farFieldMicCount) far-field)"
}

/// One unit's factory calibration compared with the expectation.
public struct FactoryCalibrationReport: Sendable, Equatable {
    public static let title = "Factory Calibration"

    public enum KeyState: String, Sendable {
        case present, missing, blank
        /// No script reported on this key.
        case unknown
    }

    public struct KeyStatus: Sendable, Equatable, Identifiable {
        public let key: FactoryCalibrationExpectation.Key
        public let state: KeyState
        /// Payload size, when a script reported it.
        public let bytes: Int?

        public var id: String { key.tag }

        /// The size disagrees with the fixed factory layout.
        public var sizeMismatch: Bool {
            guard state == .present, let bytes, let expected = key.expectedBytes else { return false }
            return bytes != expected
        }
    }

    public let keys: [KeyStatus]
    /// The audio calibration decoded from the unit's payloads, when available.
    public let unit: PuffinUnitCalibration?
    public let wifi: SysCfgCalibrationBlob?
    public let bluetooth: SysCfgCalibrationBlob?

    /// Builds the comparison from whatever the three tools reported. The audio
    /// and radio scripts know the most about their own tags; `hpdiag-factory`'s
    /// present / missing lists fill in the rest.
    public init(factory: FactoryData?, audio: AudioStatus?, radio: RadioStatus?) {
        var blobs: [String: SysCfgCalibrationBlob] = [:]
        for blob in audio?.calibration ?? [] { blobs[blob.tag] = blob }
        if let blob = radio?.calibration?.wifi { blobs["WCAL"] = blob }
        if let blob = radio?.calibration?.bt { blobs["BCAL"] = blob }

        keys = FactoryCalibrationExpectation.keys.map { key in
            if let blob = blobs[key.tag], let present = blob.present {
                let state: KeyState = !present ? .missing : (blob.blank == true ? .blank : .present)
                return KeyStatus(key: key, state: state, bytes: blob.bytes)
            }
            if let factory {
                if factory.tagsPresent.contains(key.tag) { return KeyStatus(key: key, state: .present, bytes: nil) }
                if factory.tagsMissing.contains(key.tag) { return KeyStatus(key: key, state: .missing, bytes: nil) }
            }
            return KeyStatus(key: key, state: .unknown, bytes: nil)
        }
        unit = audio?.unitCalibration
        wifi = radio?.calibration?.wifi
        bluetooth = radio?.calibration?.bt
    }

    /// At least one key was actually checked.
    public var hasData: Bool { keys.contains { $0.state != .unknown } }

    public var presentKeys: [KeyStatus] { keys.filter { $0.state == .present } }
    public var problemKeys: [KeyStatus] { keys.filter { $0.state == .missing || $0.state == .blank } }
    public var uncheckedKeys: [KeyStatus] { keys.filter { $0.state == .unknown } }

    public func state(of tag: String) -> KeyState { keys.first { $0.key.tag == tag }?.state ?? .unknown }

    /// Tweeters with calibration in SpEQ; `nil` when the payload wasn't decoded.
    public var tweeterCount: Int? {
        guard let unit, unit.versions[.speakerEQ] != nil else { return nil }
        return unit.tweeters.count
    }

    /// 1 when WFEQ decoded; `nil` when it wasn't.
    public var wooferCount: Int? {
        guard let unit, unit.versions[.wooferEQ] != nil else { return nil }
        return unit.woofer == nil ? 0 : 1
    }

    /// Calibrated drivers found (woofer + tweeters); `nil` when neither
    /// payload was decoded.
    public var driverCount: Int? {
        if tweeterCount == nil && wooferCount == nil { return nil }
        return (tweeterCount ?? 0) + (wooferCount ?? 0)
    }

    /// Far-field mic trims in MiGa; `nil` when the payload wasn't decoded.
    public var micTrimCount: Int? {
        guard let unit, unit.versions[.micGain] != nil else { return nil }
        return unit.micGainsRaw.count
    }

    /// Ways the decoded calibration departs from the factory layout. Empty
    /// when it matches (or when nothing was decoded).
    public var structureIssues: [String] {
        guard let unit else { return [] }
        var issues: [String] = []
        for tag in PuffinCalibrationTag.allCases {
            if let failure = unit.failures[tag] { issues.append(failure.errorDescription ?? "\(tag.rawValue) couldn't be decoded.") }
            if let version = unit.versions[tag], version != PuffinUnitCalibration.knownVersion {
                issues.append("\(tag.rawValue) has format version \(version); only version \(PuffinUnitCalibration.knownVersion) has been seen.")
            }
        }
        if let woofer = unit.woofer, woofer.bands.count != FactoryCalibrationExpectation.wooferBands {
            issues.append("Woofer has \(woofer.bands.count) EQ bands; the template has \(FactoryCalibrationExpectation.wooferBands).")
        }
        for driver in unit.drivers {
            if driver.isAllZero {
                issues.append("\(driver.role.title) is all zero — a placeholder, not a measurement.")
            } else if !driver.isPlausible {
                let bad = driver.bands.filter { !$0.isPlausible }.map { "band \($0.index + 1) (\($0.frequencyHz) Hz)" }
                issues.append("\(driver.role.title) has values no real calibration would hold" + (bad.isEmpty ? "." : ": " + bad.joined(separator: ", ") + "."))
            }
        }
        return issues
    }

    /// Display rows, in reading order: keys, then counts, then structure.
    public var rows: [DiagRow] {
        guard hasData else { return [] }
        var out: [DiagRow] = []
        let checked = keys.filter { $0.state != .unknown }
        let problems = problemKeys

        // 1. Do the keys exist?
        var keyNotes: [String] = []
        let sized = presentKeys.map { status in status.bytes.map { "\(status.key.tag) \($0) B" } ?? status.key.tag }
        if !sized.isEmpty { keyNotes.append("Present: " + sized.joined(separator: ", ") + ".") }
        if !uncheckedKeys.isEmpty {
            keyNotes.append("Not checked on this run: " + uncheckedKeys.map(\.key.tag).joined(separator: ", ") + ".")
        }
        out.append(DiagRow(id: "factorycal.keys", label: "Calibration Keys",
                           value: "\(checked.count - problems.count) of \(checked.count) present",
                           verdict: problems.isEmpty ? .pass : .warn,
                           note: keyNotes.isEmpty ? nil : keyNotes.joined(separator: " ")))
        for status in problems {
            out.append(DiagRow(id: "factorycal.key.\(status.key.tag)", label: "\(status.key.tag) · \(status.key.title)",
                               value: status.state == .blank ? "Blank" : "Missing", verdict: .warn,
                               note: status.key.consequence + " It can only be restored from this unit's own SysCfg backup."))
        }
        for status in keys where status.sizeMismatch {
            out.append(DiagRow(id: "factorycal.size.\(status.key.tag)", label: "\(status.key.tag) · \(status.key.title)",
                               value: "\(status.bytes ?? 0) bytes", verdict: .warn,
                               note: "The factory layout is \(status.key.expectedBytes ?? 0) bytes (\(status.key.structure)). A different size means the key was written incorrectly or truncated."))
        }

        // 2. Driver count.
        let expectedDrivers = FactoryCalibrationExpectation.driverCount
        let driverLayout = "\(FactoryCalibrationExpectation.wooferCount) woofer + \(FactoryCalibrationExpectation.tweeterCount) tweeters"
        if let count = driverCount {
            let parts = ["\(wooferCount ?? 0) woofer", "\(tweeterCount ?? 0) tweeter\((tweeterCount ?? 0) == 1 ? "" : "s")"]
            out.append(DiagRow(id: "factorycal.drivers", label: "Speaker Drivers",
                               value: "\(count) of \(expectedDrivers) calibrated (\(parts.joined(separator: " + ")))",
                               verdict: count == expectedDrivers ? .pass : .warn,
                               note: count == expectedDrivers ? nil
                                   : "A factory unit carries calibration for \(expectedDrivers) drivers: \(driverLayout)."))
        } else if state(of: "SpEQ") == .present || state(of: "WFEQ") == .present {
            out.append(DiagRow(id: "factorycal.drivers", label: "Speaker Drivers", value: "Expected \(expectedDrivers) (\(driverLayout))", verdict: .info,
                               note: "The calibration keys exist, but this run didn't return their contents, so the per-driver count wasn't verified."))
        }

        // 3. Microphone count.
        let micNote = "The mic DSP has \(FactoryCalibrationExpectation.micCount) trim boxes — \(FactoryCalibrationExpectation.internalMicCount) internal + \(FactoryCalibrationExpectation.farFieldMicCount) far-field. SysCfg stores the \(FactoryCalibrationExpectation.storedMicTrims) far-field trims; the internal mic has no stored value."
        if let count = micTrimCount {
            let expected = FactoryCalibrationExpectation.storedMicTrims
            out.append(DiagRow(id: "factorycal.mics", label: "Microphones",
                               value: "\(count) of \(expected) far-field trims stored",
                               verdict: count == expected ? .pass : .warn, note: micNote))
        } else if state(of: "MiGa") == .present {
            out.append(DiagRow(id: "factorycal.mics", label: "Microphones",
                               value: "Expected \(FactoryCalibrationExpectation.storedMicTrims) far-field trims", verdict: .info, note: micNote))
        }

        // 4. Structure against Apple's template.
        if let unit, !unit.isEmpty || !unit.failures.isEmpty {
            let issues = structureIssues
            if issues.isEmpty {
                out.append(DiagRow(id: "factorycal.structure", label: "Layout vs Factory", value: "Matches Apple's template", verdict: .pass,
                                   note: "Woofer \(FactoryCalibrationExpectation.wooferBands) EQ bands, tweeters \(FactoryCalibrationExpectation.tweeterBands) each, format version \(PuffinUnitCalibration.knownVersion), all values in the audio range."))
            } else {
                out.append(DiagRow(id: "factorycal.structure", label: "Layout vs Factory",
                                   value: "\(issues.count) difference\(issues.count == 1 ? "" : "s")", verdict: .warn,
                                   note: issues.joined(separator: " ")))
            }
            if let gain = unit.speakerGainRaw {
                out.append(DiagRow(id: "factorycal.speakerGain", label: "Speaker Gain", value: "\(gain) (stored value)", verdict: .info))
            }
        }

        // 5. Radio containers.
        var radio: [String] = []
        var radioVerdicts: [DiagVerdict] = []
        for blob in [wifi, bluetooth].compactMap({ $0 }) {
            guard let verdict = RadioStatus.Calibration.verdict(for: blob) else { continue }
            radioVerdicts.append(verdict)
            if blob.present != true { radio.append("\(blob.tag) missing"); continue }
            if blob.blank == true { radio.append("\(blob.tag) blank"); continue }
            var text = blob.tag
            if let bytes = blob.bytes { text += " \(bytes) B" }
            if let sections = blob.sections { text += " · \(sections) sections" }
            if verdict == .warn { text += " (bad container)" }
            radio.append(text)
        }
        if !radio.isEmpty {
            let verdict = DiagVerdict.worst(radioVerdicts)
            out.append(DiagRow(id: "factorycal.radio", label: "Radio Calibration", value: radio.joined(separator: ", "), verdict: verdict,
                               note: verdict == .pass ? nil : "See the Wi-Fi / Bluetooth calibration rows under Environment."))
        }
        return out
    }

    /// Worst of the judged rows; `.info` when nothing was judged.
    public var verdict: DiagVerdict {
        DiagVerdict.worst(rows.map(\.verdict).filter { $0 != .info })
    }
}

extension FullDiagnosticsReport {
    /// The factory-calibration comparison for this run; `nil` when no tool
    /// reported on any calibration key.
    public var factoryCalibration: FactoryCalibrationReport? {
        var factory: FactoryData?
        var audio: AudioStatus?
        var radio: RadioStatus?
        for result in results {
            switch result {
            case .factory(let r): factory = r
            case .audio(let r): audio = r
            case .radio(let r): radio = r
            default: break
            }
        }
        let report = FactoryCalibrationReport(factory: factory, audio: audio, radio: radio)
        return report.hasData ? report : nil
    }
}

// MARK: - Arbitrary JSON (for the NAND "raw" property dump)

/// A JSON value of any shape, kept verbatim so unrecognized properties survive
/// into the export.
public enum DiagJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DiagJSONValue])
    case object([String: DiagJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([DiagJSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: DiagJSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value.") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - Shared row / verdict helpers

extension DiagVerdict {
    /// Final verdict for a tool: the worse of what the script reported and what
    /// the numbers say. A tool that says it couldn't run (`ok == false`) is
    /// informational unless the script itself gave a verdict.
    static func resolve(ok: Bool, reported: DiagVerdict?, derived: DiagVerdict?) -> DiagVerdict {
        guard ok else { return reported ?? .info }
        return worst([reported, derived].compactMap { $0 })
    }
}

extension DiagRow {
    /// "Couldn't check" row for a tool that reported `ok == false`.
    static func status(tool: DiagTool, ok: Bool, error: String?, id: String? = nil, label: String? = nil) -> DiagRow? {
        guard !ok else { return nil }
        return DiagRow(id: id ?? "\(tool.rawValue).status", label: label ?? tool.title, value: "Couldn't check", verdict: .info,
                       note: error ?? "The pod-side check didn't complete.")
    }

    /// Free-text note from the script, shown as its own info row.
    static func note(tool: DiagTool, _ text: String?, id: String? = nil) -> DiagRow? {
        guard let text, !text.isEmpty else { return nil }
        return DiagRow(id: id ?? "\(tool.rawValue).note", label: "Note", value: text, verdict: .info)
    }
}

/// Small display formatters shared by the rows and the plain-text report.
enum DiagFormat {
    /// "16 GB", "4 MB", "512 bytes". Power-of-two sizes (partition sizes such
    /// as 4194304) use binary units; round decimal figures and everything else
    /// use decimal units (the way NAND capacity is marketed).
    static func bytes(_ n: Int) -> String {
        guard n >= 1024 else { return "\(n) bytes" }
        let binary = n % 1024 == 0 && n % 1_000_000 != 0
        let base: Double = binary ? 1024 : 1000
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(n) / base
        var unit = 0
        while value >= base, unit < units.count - 1 { value /= base; unit += 1 }
        return "\(number(value)) \(units[unit])"
    }

    /// One decimal place, dropped when it would be ".0".
    static func number(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    static func percent(_ v: Double) -> String { "\(number(v))%" }

    static func celsius(_ v: Double) -> String { "\(number(v)) °C" }

    /// Lower-case hex digits only; `nil` unless it is a full six-byte MAC.
    static func normalizedMAC(_ mac: String) -> String? {
        let hex = mac.lowercased().filter { $0.isHexDigit }
        return hex.count == 12 ? hex : nil
    }

    /// Keeps the vendor prefix, hides the unit-specific half: "d0:81:7a:…".
    static func redactedMAC(_ mac: String) -> String {
        guard let hex = normalizedMAC(mac) else { return mac }
        let chars = Array(hex)
        return "\(String(chars[0..<2])):\(String(chars[2..<4])):\(String(chars[4..<6])):…"
    }

    /// "…HQK8".
    static func redactedSerial(_ serial: String) -> String {
        serial.count > 4 ? "…" + serial.suffix(4) : serial
    }

    static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func date(fromISO8601 text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = ISO8601DateFormatter().date(from: trimmed) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: trimmed)
    }
}

// MARK: - Lenient decoding

/// Decodes an element or yields nil, so one malformed entry can't sink an array.
private struct DiagLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// A string, or a number / bool rendered as one.
private struct DiagFlexString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = b ? "true" : "false" }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = DiagFormat.number(d) }
        else { value = nil }
    }
}

extension KeyedDecodingContainer {
    /// String; numbers and bools are rendered. `nil` when absent / null / a container.
    func diagString(_ key: Key) -> String? {
        ((try? decodeIfPresent(DiagFlexString.self, forKey: key)) ?? nil)?.value
    }

    /// Number; also accepts numeric strings ("12", "3.5", "0x1c").
    func diagDouble(_ key: Key) -> Double? {
        // Strings first: some JSON decoders will happily coerce a string here.
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = t.lowercased()
            if lower.hasPrefix("0x") { return UInt64(lower.dropFirst(2), radix: 16).map { Double($0) } }
            return Double(t)
        }
        return (try? decodeIfPresent(Double.self, forKey: key)) ?? nil
    }

    /// Integer; also accepts whole-ish doubles and numeric strings.
    func diagInt(_ key: Key) -> Int? {
        if ((try? decodeIfPresent(String.self, forKey: key)) ?? nil) == nil,
           let i = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return i }
        guard let d = diagDouble(key), d.isFinite, abs(d) < 9.0e18 else { return nil }
        return Int(d.rounded())
    }

    /// Bool; also accepts 0 / non-zero and "yes" / "no" / "true" / "false".
    func diagBool(_ key: Key) -> Bool? {
        if let b = (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil { return b }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "on": return true
            case "false", "no", "n", "off", "": return false
            default: break
            }
        }
        return diagDouble(key).map { $0 != 0 }
    }

    /// Script-reported verdict, parsed leniently.
    func diagVerdict(_ key: Key) -> DiagVerdict? {
        diagString(key).flatMap { DiagVerdict(lenient: $0) }
    }

    /// Array of objects; malformed elements are dropped, a non-array is empty.
    func diagArray<T: Decodable>(_ key: Key) -> [T] {
        let items = (try? decodeIfPresent([DiagLossy<T>].self, forKey: key)) ?? nil
        return (items ?? []).compactMap(\.value)
    }

    /// Array of strings; a single string is split on commas / whitespace.
    func diagStrings(_ key: Key) -> [String] {
        if let items = (try? decodeIfPresent([DiagFlexString].self, forKey: key)) ?? nil {
            return items.compactMap(\.value).filter { !$0.isEmpty }
        }
        guard let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil else { return [] }
        return s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
    }
}
