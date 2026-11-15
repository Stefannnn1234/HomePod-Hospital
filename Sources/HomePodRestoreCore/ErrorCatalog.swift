import Foundation

/// Plain-English explanations for the messages people ask about most.
/// Based on the Troubleshooting section of the homepod-restore guide.
public struct KnownIssue: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        /// Looks scary in the log but is expected. Never stops a restore.
        case normal = 0
        /// Worth knowing, restore may still finish.
        case warning = 1
        /// The restore failed because of this.
        case fatal = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Category: String, Sendable {
        case firmware      // wrong/unsigned ipsw, bad download
        case connection    // adapter, cable, orientation, port
        case mac           // Mac-side tools/software
        case hardwareNAND  // likely NAND failure
        case hardwareSoC   // likely A8 SoC failure
        case hardwareOther
        case transient     // just try again
        case informational
    }

    public let id: String
    public let title: String
    public let explanation: String
    public let suggestions: [String]
    public let severity: Severity
    public let category: Category
    /// Case-insensitive substrings; any match triggers the issue.
    public let patterns: [String]

    public var isHardware: Bool {
        category == .hardwareNAND || category == .hardwareSoC || category == .hardwareOther
    }
}

public enum ErrorCatalog {
    public static let reseat = "Unplug power, then unplug USB. Re-seat the adapter so it sits flat, then connect USB first and power last."

    public static let all: [KnownIssue] = [
        // ---- Normal noise -------------------------------------------------
        KnownIssue(id: "noise.reverseproxy",
                   title: "Lots of \"ReverseProxy\" / \"No data to read\" messages",
                   explanation: "These repeat for 10–15 minutes during every restore. They're normal — the HomePod is busy installing.",
                   suggestions: ["Leave everything connected and wait."],
                   severity: .normal, category: .informational,
                   patterns: ["ReverseProxy[", "No data to read (timeout)"]),
        KnownIssue(id: "noise.ampctl",
                   title: "\"ampctl failure\" or \"RamrodErrorDomain\"",
                   explanation: "This is normal on HomePods and doesn't affect the restore.",
                   suggestions: ["Nothing to do — keep waiting."],
                   severity: .normal, category: .informational,
                   patterns: ["ampctl failure", "RamrodErrorDomain"]),

        // ---- Firmware / signing ---------------------------------------------
        KnownIssue(id: "fw.notEligible",
                   title: "Apple won't sign this firmware",
                   explanation: "Apple only allows certain HomePod software versions to be installed. This file is either no longer signed, or the restore tool on this Mac is the wrong version.",
                   suggestions: [
                    "Use the recommended firmware from the Firmware tab (re-download it if it's old).",
                    "Open Setup and make sure every tool shows a green check. Run \"Install / Repair tools\" if idevicerestore has a warning.",
                   ],
                   severity: .fatal, category: .firmware,
                   patterns: ["isn't eligible for the requested build", "Unable to get SHSH blobs", "Unable to send iBEC", "This device isn't eligible"]),
        KnownIssue(id: "fw.extract",
                   title: "The firmware file couldn't be opened",
                   explanation: "The .ipsw file is damaged, incomplete, or your Mac ran out of disk space while unpacking it.",
                   suggestions: ["Free up at least 10 GB of disk space.", "Delete the firmware in the Firmware tab and download it again."],
                   severity: .fatal, category: .firmware,
                   patterns: ["Unable to extract filesystem", "Unable to extract", "ERROR: Unable to open IPSW", "not a valid IPSW", "Unable to read BuildManifest"]),
        KnownIssue(id: "fw.verify",
                   title: "The installed software failed verification",
                   explanation: "Data got corrupted on the way to the HomePod. This is usually a flaky USB connection or cable.",
                   suggestions: [reseat, "Try a different USB cable or port (avoid unpowered hubs).", "Try again."],
                   severity: .fatal, category: .connection,
                   patterns: ["Status: Verification Error"]),

        // ---- Transient ------------------------------------------------------
        KnownIssue(id: "transient.nitrogen",
                   title: "Nitrogen firmware flash failed",
                   explanation: "A known hiccup that usually goes away on a second try.",
                   suggestions: [reseat, "Start the restore again from the beginning."],
                   severity: .fatal, category: .transient,
                   patterns: ["failure when attempting to flash the nitrogen firmware"]),

        // ---- Hardware ---------------------------------------------------------
        KnownIssue(id: "hw.nand",
                   title: "Possible storage (NAND) failure",
                   explanation: "The HomePod's storage chip didn't respond. This usually means the NAND has failed, which is a hardware repair.",
                   suggestions: [
                    "Try once more after restarting your Mac to rule out a fluke.",
                    "If it happens again, the HomePod needs a board-level repair — Nic's Fix can help.",
                   ],
                   severity: .fatal, category: .hardwareNAND,
                   patterns: ["Waiting on NAND", "Timeout waiting for NVRAM Service", "Status: Disk Failure", "Status: Failed to mount filesystems"]),
        KnownIssue(id: "hw.soc",
                   title: "The HomePod didn't start the restore software",
                   explanation: "The HomePod accepted the first stage but never came back. This can be a bad USB connection, but if it keeps happening it points to an A8 processor (SoC) failure.",
                   suggestions: [
                    reseat,
                    "Restart your Mac and try again.",
                    "If it keeps failing at the same spot, the logic board likely needs repair.",
                   ],
                   severity: .fatal, category: .hardwareSoC,
                   patterns: ["Possibly invalid iBEC", "Possibly invalid iBSS", "Device failed to enter restore mode", "did not reconnect in recovery mode"]),
        KnownIssue(id: "hw.sep",
                   title: "Secure Enclave firmware failed to load",
                   explanation: "The HomePod's security chip rejected its firmware. Try again; if it repeats it's likely a hardware fault.",
                   suggestions: [reseat, "Try the restore one more time."],
                   severity: .fatal, category: .hardwareOther,
                   patterns: ["Failed to load SEP Firmware"]),

        // ---- Connection --------------------------------------------------------
        KnownIssue(id: "conn.pwn",
                   title: "Couldn't unlock the HomePod",
                   explanation: "The HomePod didn't respond to the unlock step. Most of the time this is the adapter or cable; occasionally it's a hardware fault.",
                   suggestions: [
                    "Make sure the HomePod is upside down and the adapter sits flat on the port (clean off old adhesive).",
                    "Connect USB first, then power. Order matters.",
                    "Try a different USB port directly on your Mac (no hubs) and a different cable.",
                    "Restart your Mac and try again.",
                   ],
                   severity: .fatal, category: .connection,
                   patterns: ["gaster: pwn failed", "Unable to pwn", "No device found"]),
        KnownIssue(id: "conn.lost",
                   title: "The HomePod disconnected",
                   explanation: "USB connection to the HomePod was lost during the restore.",
                   suggestions: [reseat, "Don't touch the HomePod, adapter or cable while restoring.", "Try again."],
                   severity: .fatal, category: .connection,
                   patterns: ["Device disconnected", "Unable to connect to device", "Unable to open device", "ERROR: Unable to discover device mode"]),

        // ---- Mac -------------------------------------------------------------
        KnownIssue(id: "mac.usbmuxd",
                   title: "Your Mac's device service isn't responding",
                   explanation: "macOS talks to the HomePod through a background service (usbmuxd).",
                   suggestions: ["Restart your Mac, then try again."],
                   severity: .warning, category: .mac,
                   patterns: ["make sure that usbmuxd is running"]),
        KnownIssue(id: "mac.irecvinit",
                   title: "idevicerestore build error (irecv_init)",
                   explanation: "A compile error from building idevicerestore with newer libirecovery.",
                   suggestions: ["Open Setup → Install / Repair tools. The installer applies the fix from the guide automatically."],
                   severity: .fatal, category: .mac,
                   patterns: ["irecv_init"]),
    ]

    /// Every issue whose pattern appears in `line`.
    public static func matches(in line: String) -> [KnownIssue] {
        all.filter { issue in issue.patterns.contains { line.range(of: $0, options: .caseInsensitive) != nil } }
    }

    public static func issue(id: String) -> KnownIssue? { all.first { $0.id == id } }
}
