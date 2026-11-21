import Foundation

/// Only one HomePod runs the checkm8 unlock at a time. The exploit is timing
/// sensitive, and stock gaster can't choose between several DFU devices.
public actor UnlockCoordinator {
    public static let shared = UnlockCoordinator()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// A single restore / health check for one HomePod.
public final class RestoreJob: @unchecked Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// Full erase-restore.
        case restore
        /// Unlock only: proves USB + DFU + SoC respond. Doesn't change anything.
        case quickCheck
        /// Unlock + boot the restore ramdisk, then stop. Doesn't erase.
        case bootTest

        public var title: String {
            switch self {
            case .restore: return "Restore"
            case .quickCheck: return "Quick check"
            case .bootTest: return "Boot test"
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        case running
        case succeeded
        case failed(issueID: String?, message: String)
        case cancelled
    }

    public struct Snapshot: Sendable {
        public var kind: Kind
        public var outcome: Outcome
        public var phase: RestorePhase
        public var phaseProgress: Double?
        public var overallProgress: Double
        public var status: String
        public var issues: [KnownIssue]
        public var hardware: HardwareInfo
        public var startedAt: Date
        public var finishedAt: Date?
        public var logURL: URL
        public var recentLines: [String]
        public var unlockAttempts: Int
        /// Increases with every update, so late-arriving older snapshots can be ignored.
        public var sequence: Int = 0

        public var primaryIssue: KnownIssue? {
            if case .failed(let id?, _) = outcome { return ErrorCatalog.issue(id: id) }
            return nil
        }
    }

    public let id = UUID()
    public let kind: Kind
    public let ecid: UInt64
    public let locationID: UInt32
    public let firmware: FirmwareItem?
    public let gasterTargetsECID: Bool
    public let logURL: URL

    private let lock = NSLock()
    private var parser = RestoreLogParser()
    private var snapshot: Snapshot
    private var current: ProcessRunner?
    private var cancelled = false
    private let onUpdate: @Sendable (Snapshot) -> Void
    private var lastEmit = Date.distantPast

    public init(kind: Kind, ecid: UInt64, locationID: UInt32, firmware: FirmwareItem?, gasterTargetsECID: Bool,
                onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        self.kind = kind
        self.ecid = ecid
        self.locationID = locationID
        self.firmware = firmware
        self.gasterTargetsECID = gasterTargetsECID
        self.onUpdate = onUpdate
        AppPaths.ensure()
        let log = AppPaths.logs.appendingPathComponent("\(kind.rawValue)-\(String(format: "%016llX", ecid).suffix(6))-\(IPSWBuilder.stamp()).log")
        logURL = log
        snapshot = Snapshot(kind: kind, outcome: .running, phase: .waiting, phaseProgress: nil, overallProgress: 0,
                            status: "Waiting to start", issues: [], hardware: HardwareInfo(), startedAt: Date(),
                            finishedAt: nil, logURL: log, recentLines: [], unlockAttempts: 0)
    }

    public var ecidHex: String { String(format: "0x%016llX", ecid) }
    public var currentSnapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return snapshot }

    public func cancel() {
        lock.lock(); cancelled = true; let r = current; lock.unlock()
        r?.cancel()
    }

    // MARK: - Run

    public func run() async {
        writeLog("HomePod Hospital — \(kind.title) for ECID \(ecidHex) at \(Date())\n")
        if let fw = firmware { writeLog("Firmware: \(fw.displayName) — \(fw.path)\n") }
        do {
            // 1. Unlock (pwn) — serialized across all HomePods.
            setStatus(.unlocking, "Waiting for unlock slot…")
            try await UnlockCoordinator.shared.run { try await self.unlock() }
            try checkCancelled()

            if kind == .quickCheck {
                finish(.succeeded, status: "HomePod responded and unlocked successfully")
                return
            }

            // 2. Restore / boot test
            guard let firmware else { throw JobError.message("No firmware selected.") }
            try await runIdevicerestore(firmware: firmware)
        } catch JobError.cancelled {
            finish(.cancelled, status: "Cancelled")
        } catch JobError.issue(let id, let msg) {
            finish(.failed(issueID: id, message: msg), status: msg)
        } catch JobError.message(let msg) {
            finish(.failed(issueID: nil, message: msg), status: msg)
        } catch {
            finish(.failed(issueID: nil, message: error.localizedDescription), status: error.localizedDescription)
        }
    }

    private enum JobError: Error {
        case cancelled
        case issue(String, String)
        case message(String)
    }

    private func checkCancelled() throws {
        lock.lock(); let c = cancelled; lock.unlock()
        if c { throw JobError.cancelled }
    }

    private func environment() -> [String: String] {
        var env = ToolEnvironment.standard
        if gasterTargetsECID { env["GASTER_ECID"] = ecidHex }
        env["USB_TIMEOUT"] = "10"
        return env
    }

    private func unlock() async throws {
        guard let gaster = ToolLocator.locate(.gaster)?.url else {
            throw JobError.message("gaster isn't installed. Open Setup to install the tools.")
        }
        setStatus(.unlocking, "Unlocking (checkm8)…")
        var lastOutput = ""
        for attempt in 1...3 {
            try checkCancelled()
            lock.sync { snapshot.unlockAttempts = attempt }
            if attempt > 1 { setStatus(.unlocking, "Unlocking — attempt \(attempt) of 3…") }
            let (ok, out) = try await runTool(gaster, ["pwn"], timeout: 60)
            lastOutput = out
            if ok && out.contains("Now you can boot untrusted images.") {
                setStatus(.unlocking, "Unlocked — resetting USB")
                _ = try await runTool(gaster, ["reset"], timeout: 20)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let issue = ErrorCatalog.issue(id: "conn.pwn")!
        writeLog("gaster pwn failed after 3 attempts.\n\(lastOutput.suffix(1500))\n")
        throw JobError.issue(issue.id, issue.title)
    }

    private func runIdevicerestore(firmware: FirmwareItem) async throws {
        guard let tool = ToolLocator.locate(.idevicerestore)?.url else {
            throw JobError.message("idevicerestore isn't installed. Open Setup to install the tools.")
        }
        var args = ["-d", "-e", "-y", "-i", ecidHex, "-C", AppPaths.restoreCache.path]
        if kind == .bootTest { args.append("-z") }
        args.append(firmware.path)

        setStatus(.preparing, "Starting restore")
        let runner = ProcessRunner(executable: tool, arguments: args, environment: environment(),
                                   logFile: nil)
        lock.sync { current = runner }
        writeLog("$ \(runner.commandLine)\n")

        // Stall watchdog: tell the user (but don't kill — big restores are slow).
        let started = Date()
        let lastLineAt = LockedDate(Date())
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Date().timeIntervalSince(lastLineAt.value) > 600 {
                    let s: Snapshot = self.lock.sync {
                        self.snapshot.status = "No progress for 10 minutes — if it stays stuck, unplug power, then USB, and try again."
                        self.snapshot.sequence += 1
                        return self.snapshot
                    }
                    self.onUpdate(s)
                }
            }
        }
        let result = try await runner.run { [weak self] line in
            lastLineAt.value = Date()
            self?.handle(line: line)
        }
        watchdog.cancel()
        let p: RestoreLogParser = lock.sync { current = nil; return parser }
        writeLog("[idevicerestore exit \(result.exitCode) after \(Int(Date().timeIntervalSince(started)))s]\n")

        if result.wasCancelled { throw JobError.cancelled }
        switch kind {
        case .bootTest:
            if result.exitCode == 0 && p.enteredRestoreMode {
                finish(.succeeded, status: "HomePod booted into restore mode — hardware looks healthy")
                return
            }
        default:
            if result.exitCode == 0 || p.restoreFinished {
                finish(.succeeded, status: "Restore complete")
                return
            }
        }
        if let issue = p.primaryIssue {
            throw JobError.issue(issue.id, issue.title)
        }
        throw JobError.message(p.lastError.map { "The restore stopped: \($0)" } ?? "The restore stopped unexpectedly (exit code \(result.exitCode)).")
    }

    private func runTool(_ tool: URL, _ args: [String], timeout: TimeInterval) async throws -> (Bool, String) {
        let r = ProcessRunner(executable: tool, arguments: args, environment: environment())
        lock.sync { current = r }
        writeLog("$ \(r.commandLine)\n")
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            r.cancel()
        }
        let res = try await r.run { [weak self] line in self?.handle(line: line) }
        timer.cancel()
        lock.sync { current = nil }
        try checkCancelled()
        return (res.exitCode == 0, res.output)
    }

    private func handle(line: String) {
        writeLog(line + "\n")
        lock.lock()
        let changed = parser.consume(line)
        snapshot.phase = max(snapshot.phase, parser.phase)
        snapshot.phaseProgress = parser.phaseProgress
        snapshot.overallProgress = parser.overallProgress
        if !parser.statusLine.isEmpty { snapshot.status = parser.statusLine }
        snapshot.issues = parser.issues
        snapshot.hardware = parser.hardware
        snapshot.recentLines.append(line)
        if snapshot.recentLines.count > 400 { snapshot.recentLines.removeFirst(snapshot.recentLines.count - 400) }
        let now = Date()
        let emit = changed || now.timeIntervalSince(lastEmit) > 0.5
        if emit { lastEmit = now }
        snapshot.sequence += 1
        let s = snapshot
        lock.unlock()
        if emit { onUpdate(s) }
    }

    private func setStatus(_ phase: RestorePhase, _ status: String) {
        lock.lock()
        if phase > snapshot.phase { snapshot.phase = phase }
        snapshot.status = status
        snapshot.sequence += 1
        let s = snapshot
        lock.unlock()
        onUpdate(s)
    }

    private func finish(_ outcome: Outcome, status: String) {
        lock.lock()
        snapshot.outcome = outcome
        snapshot.status = status
        snapshot.finishedAt = Date()
        if outcome == .succeeded {
            snapshot.overallProgress = 1
            if kind == .restore { snapshot.phase = .done }
        }
        snapshot.sequence += 1
        let s = snapshot
        lock.unlock()
        writeLog("Result: \(outcome) — \(status)\n")
        onUpdate(s)
    }

    private let logLock = NSLock()
    private var logHandle: FileHandle?

    private func writeLog(_ text: String) {
        logLock.lock(); defer { logLock.unlock() }
        if logHandle == nil {
            let url = logURL
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
        }
        logHandle?.write(Data(text.utf8))
    }

    deinit { try? logHandle?.close() }
}

final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ v: Date) { _value = v }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
