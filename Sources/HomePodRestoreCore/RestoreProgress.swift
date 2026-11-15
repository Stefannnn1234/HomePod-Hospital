import Foundation

/// The friendly steps shown to the user while a HomePod restores.
public enum RestorePhase: Int, CaseIterable, Comparable, Sendable {
    case waiting = 0
    case unlocking
    case preparing
    case booting
    case checkingHardware
    case installing
    case verifying
    case finishing
    case done

    public static func < (a: RestorePhase, b: RestorePhase) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .waiting: return "Waiting to start"
        case .unlocking: return "Unlocking HomePod"
        case .preparing: return "Preparing software"
        case .booting: return "Starting restore mode"
        case .checkingHardware: return "Checking hardware"
        case .installing: return "Installing HomePod software"
        case .verifying: return "Verifying"
        case .finishing: return "Finishing up"
        case .done: return "Restore complete"
        }
    }

    public var detail: String {
        switch self {
        case .waiting: return ""
        case .unlocking: return "Running the checkm8 exploit so the HomePod accepts the restore."
        case .preparing: return "Getting the firmware ready and asking Apple to sign it."
        case .booting: return "Sending the restore software to the HomePod."
        case .checkingHardware: return "Talking to the HomePod's storage and chips."
        case .installing: return "This takes 10–15 minutes. Lots of log messages are normal — don't touch anything."
        case .verifying: return "Making sure everything was written correctly."
        case .finishing: return "Flashing firmware and wrapping up."
        case .done: return "All done!"
        }
    }

    /// Rough share of total time, used to blend into one overall progress bar.
    var weight: Double {
        switch self {
        case .waiting: return 0
        case .unlocking: return 0.03
        case .preparing: return 0.05
        case .booting: return 0.07
        case .checkingHardware: return 0.05
        case .installing: return 0.6
        case .verifying: return 0.15
        case .finishing: return 0.05
        case .done: return 0
        }
    }

    /// The steps listed in the UI checklist.
    public static let visibleSteps: [RestorePhase] = [.unlocking, .preparing, .booting, .checkingHardware, .installing, .verifying, .finishing]
}

/// Hardware details idevicerestore prints after the HomePod enters restore mode.
public struct HardwareInfo: Equatable, Sendable {
    public var boardID: Int?
    public var chipID: Int?
    public var uniqueChipID: String?
    public var productionMode: Bool?
    public var securityDomain: Int?
    public var nandWaitSeconds: Double?

    public var isEmpty: Bool { boardID == nil && chipID == nil && uniqueChipID == nil }
}

/// Turns idevicerestore / gaster output into phases, a progress value and
/// diagnoses. Feed it every output line in order.
public struct RestoreLogParser: Sendable {
    public private(set) var phase: RestorePhase = .waiting
    /// 0...1 within the current phase, when known.
    public private(set) var phaseProgress: Double?
    public private(set) var statusLine: String = ""
    public private(set) var hardware = HardwareInfo()
    public private(set) var issues: [KnownIssue] = []
    public private(set) var restoreFinished = false
    public private(set) var enteredRestoreMode = false
    public private(set) var lastError: String?
    public private(set) var lineCount = 0

    private var currentOperation: Int?
    private var inHardwareBlock = false
    private var nandStart: Date?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// Combined 0...1 progress across all phases.
    public var overallProgress: Double {
        var total = 0.0
        for p in RestorePhase.visibleSteps {
            if p < phase { total += p.weight }
            else if p == phase { total += p.weight * (phaseProgress ?? 0) }
        }
        if phase == .done { return 1 }
        return min(total, 0.99)
    }

    /// The most relevant problem: the latest fatal issue, otherwise the latest warning.
    public var primaryIssue: KnownIssue? {
        issues.last(where: { $0.severity == .fatal }) ?? issues.last(where: { $0.severity == .warning })
    }

    public var hardwareIssues: [KnownIssue] { issues.filter { $0.isHardware } }

    @discardableResult
    public mutating func consume(_ rawLine: String) -> Bool {
        lineCount += 1
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        let before = (phase, phaseProgress, statusLine)

        // Diagnoses
        for issue in ErrorCatalog.matches(in: line) where !issues.contains(issue) {
            issues.append(issue)
        }
        if line.hasPrefix("ERROR:") || line.hasPrefix("ERROR ") { lastError = line }

        // Progress bar: "[=====      ]  45.0%"
        if line.hasPrefix("["), let pct = Self.parsePercent(line) {
            phaseProgress = pct / 100.0
            return before.1 != phaseProgress
        }

        // Hardware block
        if line.hasPrefix("Hardware Information") { inHardwareBlock = true; advance(to: .checkingHardware); setStatus("Reading hardware information") }
        if inHardwareBlock {
            if let v = Self.value(after: "BoardID:", in: line) { hardware.boardID = Int(v) }
            else if let v = Self.value(after: "ChipID:", in: line) { hardware.chipID = Int(v) }
            else if let v = Self.value(after: "UniqueChipID:", in: line) { hardware.uniqueChipID = v }
            else if let v = Self.value(after: "SecurityDomain:", in: line) { hardware.securityDomain = Int(v) }
            else if let v = Self.value(after: "ProductionMode:", in: line) { hardware.productionMode = (v == "true"); inHardwareBlock = false }
        }

        // gaster
        if line.contains("Stage: RESET") || line.contains("[IOKit] Waiting for the USB handle") { advance(to: .unlocking) }
        if line.contains("Now you can boot untrusted images.") { advance(to: .unlocking); setStatus("HomePod unlocked") }

        // idevicerestore phases
        if line.hasPrefix("Extracting BuildManifest") || line.hasPrefix("Using cached filesystem") || line.hasPrefix("Extracting filesystem from IPSW") {
            advance(to: .preparing)
            if line.hasPrefix("Extracting filesystem") { setStatus("Unpacking firmware (one-time)") }
        }
        if line.hasPrefix("Getting ApNonce") || line.contains("Requesting SHSH blobs") || line.contains("TSS request") && phase <= .preparing {
            advance(to: .preparing); setStatus("Asking Apple to sign the firmware")
        }
        if line.hasPrefix("Sending iBSS") || line.hasPrefix("Sending iBEC") || line.hasPrefix("Entering recovery mode") || line.hasPrefix("Recovery Mode Environment") || line.hasPrefix("Sending RestoreRamDisk") || line.hasPrefix("Sending KernelCache") || line.hasPrefix("Sending DeviceTree") || line.hasPrefix("Sending RestoreKernelCache") || line.hasPrefix("Waiting for device to enter restore mode") {
            advance(to: .booting)
            setStatus(Self.friendlySend(line))
        }
        if line.hasPrefix("Device is now in restore mode") || line.hasPrefix("About to restore device") || line.hasPrefix("Connected to com.apple.mobile.restored") {
            enteredRestoreMode = true
            advance(to: .checkingHardware)
            setStatus("HomePod is in restore mode")
        }

        // Restore operations: "Restoring image (13)"
        if let (name, op) = Self.parseOperation(line) {
            currentOperation = op
            if nandStart != nil && op != 28, let start = nandStart {
                hardware.nandWaitSeconds = now().timeIntervalSince(start)
                nandStart = nil
            }
            switch op {
            case 28: // WAIT_FOR_NAND
                nandStart = now()
                advance(to: .checkingHardware); setStatus("Checking storage (NAND)")
            case 13, 26, 42, 52, 67, 68: // restore image, install root, wipe, resize, protected vol
                advance(to: .installing); setStatus(name)
                if op == 13 { phaseProgress = 0 }
            case 14, 15: // verify, check filesystems
                advance(to: .verifying); setStatus(name)
                if op == 14 { phaseProgress = 0 }
            case 18, 16, 17, 27, 29, 31, 35, 46, 57, 58, 61, 77:
                if phase >= .installing { advance(to: .finishing) }
                setStatus(name)
            default:
                setStatus(name)
            }
        }

        if line.hasPrefix("Status: Restore Finished") || line == "DONE" {
            restoreFinished = true
            advance(to: .done)
            setStatus("Restore complete")
        }

        return before.0 != phase || before.1 != phaseProgress || before.2 != statusLine
    }

    private mutating func advance(to p: RestorePhase) {
        if p > phase {
            phase = p
            phaseProgress = nil
        }
    }

    private mutating func setStatus(_ s: String) { statusLine = s }

    static func parsePercent(_ line: String) -> Double? {
        guard let close = line.lastIndex(of: "]") else { return nil }
        let tail = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard tail.hasSuffix("%") else { return nil }
        return Double(tail.dropLast().trimmingCharacters(in: .whitespaces))
    }

    static func parseOperation(_ line: String) -> (String, Int)? {
        // "<name> (<number>)" with nothing after
        guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { return nil }
        let num = line[line.index(after: open)..<line.index(before: line.endIndex)]
        guard let n = Int(num), n >= 0, n < 200 else { return nil }
        let name = line[..<open].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.first!.isUppercase, !name.contains(":") else { return nil }
        return (name, n)
    }

    static func value(after key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
    }

    static func friendlySend(_ line: String) -> String {
        if line.hasPrefix("Sending iBSS") { return "Sending first-stage bootloader" }
        if line.hasPrefix("Sending iBEC") { return "Sending second-stage bootloader" }
        if line.hasPrefix("Sending RestoreRamDisk") { return "Sending restore environment" }
        if line.hasPrefix("Sending KernelCache") || line.hasPrefix("Sending RestoreKernelCache") { return "Sending kernel" }
        if line.hasPrefix("Waiting for device to enter restore mode") { return "Waiting for restore mode (can take a minute)" }
        return "Starting restore mode"
    }
}
