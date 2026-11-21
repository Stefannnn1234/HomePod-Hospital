import Foundation

// MARK: - Per-ECID hardware health tracking

/// SEP (Secure Enclave Processor) status.
public enum SEPStatus: String, Codable, Sendable {
    case unknown
    case working
    case dead

    public var label: String {
        switch self {
        case .unknown: return "Not tested"
        case .working: return "Working"
        case .dead:    return "Not working"
        }
    }

    public var explanation: String {
        switch self {
        case .unknown: return "Run a restore or boot test to find out."
        case .working: return "The security chip responded normally."
        case .dead:    return "The security chip (SEP) can't load its firmware. Normal HomePod software can't be installed, but other boot modes still work."
        }
    }
}

/// NAND flash storage status.
public enum NANDStatus: String, Codable, Sendable {
    case unknown
    case healthy
    case degraded
    case failed

    public var label: String {
        switch self {
        case .unknown:  return "Not tested"
        case .healthy:  return "Healthy"
        case .degraded: return "Degraded"
        case .failed:   return "Failed"
        }
    }

    public var explanation: String {
        switch self {
        case .unknown:  return "A full restore tests storage automatically."
        case .healthy:  return "Storage responded normally."
        case .degraded: return "Storage has errors but may still be usable. A restore might work if the chip can be reformatted."
        case .failed:   return "Storage isn't responding. Persistent data can't be saved."
        }
    }
}

/// Overall board assessment.
public enum BoardAssessment: String, Codable, Sendable {
    case unknown
    case fullyFunctional
    case partiallyFunctional
    case partsOnly

    public var label: String {
        switch self {
        case .unknown:             return "Not assessed"
        case .fullyFunctional:     return "Fully functional"
        case .partiallyFunctional: return "Partially functional"
        case .partsOnly:           return "Parts donor"
        }
    }

    public var explanation: String {
        switch self {
        case .unknown:             return "Run a restore or health check to assess this board."
        case .fullyFunctional:     return "Everything works. This HomePod can be restored and used normally."
        case .partiallyFunctional: return "Some features don't work, but this board can still be used for diagnostics, data recovery, or experimental projects."
        case .partsOnly:           return "Too many components have failed for this board to be useful on its own. Its working parts (display, speakers, power supply) can be salvaged."
        }
    }
}

/// A boot option the user can choose, with availability info.
public struct BootOption: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let icon: String
    public let description: String
    public let available: Bool
    /// Shown when the option is unavailable.
    public let unavailableReason: String?

    public init(id: String, title: String, icon: String, description: String,
                available: Bool, unavailableReason: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.description = description
        self.available = available
        self.unavailableReason = unavailableReason
    }
}

/// Persistent health record for one logic board, keyed by ECID.
public struct BoardHealthRecord: Codable, Sendable {
    public var ecid: UInt64
    public var sep: SEPStatus
    public var nand: NANDStatus
    public var lastChecked: Date
    /// Freeform notes from detection (e.g. specific error messages).
    public var detectionNotes: [String]

    public init(ecid: UInt64, sep: SEPStatus = .unknown, nand: NANDStatus = .unknown,
                lastChecked: Date = Date(), detectionNotes: [String] = []) {
        self.ecid = ecid
        self.sep = sep
        self.nand = nand
        self.lastChecked = lastChecked
        self.detectionNotes = detectionNotes
    }

    public var assessment: BoardAssessment {
        switch (sep, nand) {
        case (.unknown, .unknown):
            return .unknown
        case (.working, .healthy), (.working, .unknown), (.unknown, .healthy):
            return .fullyFunctional
        case (.dead, .failed):
            return .partsOnly
        default:
            return .partiallyFunctional
        }
    }

    public var ecidShort: String {
        String(format: "%016llX", ecid).suffix(6).description
    }

    /// The boot options available for a board with this health profile.
    public var bootOptions: [BootOption] {
        var options: [BootOption] = []

        let canRestore = sep != .dead && nand != .failed
        options.append(BootOption(
            id: "restore",
            title: "Restore HomePod software",
            icon: "arrow.counterclockwise",
            description: "Erase and install normal HomePod (audioOS) software.",
            available: canRestore,
            unavailableReason: sep == .dead
                ? "Needs a working security chip"
                : nand == .failed ? "Needs working storage" : nil
        ))

        // SSH ramdisk is available whenever DFU works (always, for boards we can talk to).
        options.append(BootOption(
            id: "sshrd",
            title: "Boot SSH ramdisk",
            icon: "terminal",
            description: "Boot into a diagnostic shell for data recovery and inspection.",
            available: true
        ))

        // Factory DIAGS — available whenever DFU works.
        options.append(BootOption(
            id: "diags",
            title: "Boot Factory DIAGS",
            icon: "wrench.and.screwdriver",
            description: "Boot Apple's factory diagnostics for hardware testing and SysCfg access.",
            available: true
        ))

        // Linux — works from RAM, doesn't need NAND or SEP.
        let linuxNote: String? = nand == .failed || nand == .degraded
            ? "Will run from RAM only (no persistent storage)"
            : nil
        options.append(BootOption(
            id: "linux",
            title: "Boot Nicotine (Linux)",
            icon: "desktopcomputer",
            description: "Revive it as a standalone AirPlay and Bluetooth speaker running Nicotine (Linux)."
                + (linuxNote.map { " " + $0 + "." } ?? ""),
            available: true
        ))

        // Attempt restore with reformat flag — only relevant for degraded NAND.
        if nand == .degraded && sep != .dead {
            options.append(BootOption(
                id: "restore-reformat",
                title: "Restore with NAND reformat",
                icon: "arrow.counterclockwise.circle",
                description: "Attempt a restore that reformats storage first. May succeed if the chip isn't fully dead.",
                available: true
            ))
        }

        return options
    }

    // MARK: - Detection from restore/log data

    /// Update this record from a finished restore snapshot.
    public mutating func update(from snapshot: RestoreJob.Snapshot) {
        lastChecked = Date()

        // SEP detection: failure at load_sep_os / SEP firmware
        let lines = snapshot.recentLines.joined(separator: "\n")
        if lines.contains("Failed to load SEP Firmware") ||
           lines.contains("load_sep_os") ||
           lines.contains("SEP ROM boot panic") {
            sep = .dead
            if !detectionNotes.contains("SEP firmware load failed") {
                detectionNotes.append("SEP firmware load failed")
            }
        } else if snapshot.outcome == .succeeded && snapshot.kind == .restore {
            // A successful full restore means SEP is working.
            sep = .working
        }

        // NAND detection
        let hasNANDIssue = snapshot.issues.contains { $0.category == .hardwareNAND }
        if hasNANDIssue ||
           lines.contains("NAND_UNC") ||
           lines.contains("kIOReturnUnformattedMedia") ||
           lines.contains("GEB detected failure") ||
           lines.contains("lbaFormatted: NO") {

            let isSevere = lines.contains("NAND_UNC") ||
                           lines.contains("GEB detected failure") ||
                           hasNANDIssue
            nand = isSevere ? .failed : .degraded

            if lines.contains("NAND_UNC") && !detectionNotes.contains("Uncorrectable NAND errors") {
                detectionNotes.append("Uncorrectable NAND errors")
            }
            if lines.contains("lbaFormatted: NO") && !detectionNotes.contains("NAND not formatted") {
                detectionNotes.append("NAND not formatted")
            }
            if lines.contains("[255,255]") && !detectionNotes.contains("SysCfg location missing") {
                detectionNotes.append("SysCfg location missing")
            }
        } else if snapshot.outcome == .succeeded && snapshot.kind == .restore {
            nand = .healthy
        }
    }

    /// Update from UART log text (if serial is connected).
    public mutating func updateFromUART(_ log: String) {
        lastChecked = Date()

        if log.contains("SEP ROM boot panic") {
            sep = .dead
            if !detectionNotes.contains("SEP ROM boot panic (UART)") {
                detectionNotes.append("SEP ROM boot panic (UART)")
            }
        }

        if log.contains("NAND_UNC") {
            nand = (nand == .failed) ? .failed : .degraded
            if !detectionNotes.contains("NAND_UNC errors (UART)") {
                detectionNotes.append("NAND_UNC errors (UART)")
            }
        }

        if log.contains("ASP") && log.contains("GEB detected failure") {
            nand = .failed
            if !detectionNotes.contains("ASP GEB failure (UART)") {
                detectionNotes.append("ASP GEB failure (UART)")
            }
        }
    }
}

// MARK: - Persistence (UserDefaults, keyed by ECID hex string)

public enum BoardHealthStore {
    private static let key = "boardHealthRecords"

    public static func load() -> [UInt64: BoardHealthRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([BoardHealthRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.ecid, $0) })
    }

    public static func save(_ records: [UInt64: BoardHealthRecord]) {
        let arr = Array(records.values)
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public static func record(for ecid: UInt64) -> BoardHealthRecord? {
        load()[ecid]
    }

    public static func update(_ record: BoardHealthRecord) {
        var all = load()
        all[record.ecid] = record
        save(all)
    }
}
