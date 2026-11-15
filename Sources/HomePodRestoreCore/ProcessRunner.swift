import Foundation

/// Runs a command-line tool, streaming its combined stdout/stderr line by line.
/// Progress bars that redraw with `\r` are delivered as separate lines too.
public final class ProcessRunner: @unchecked Sendable {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let output: String
        public let wasCancelled: Bool
    }

    public let executable: URL
    public let arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL?
    public var logFile: URL?

    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    private var collected = ""
    private var cancelled = false
    private var logHandle: FileHandle?

    public init(executable: URL, arguments: [String], environment: [String: String] = ToolEnvironment.standard, currentDirectory: URL? = nil, logFile: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.logFile = logFile
    }

    /// Human-readable command line, for logs and support reports.
    public var commandLine: String {
        ([executable.path] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    public var isRunning: Bool { process.isRunning }

    /// Starts the process and returns when it exits. `onLine` is called on a
    /// background queue for every line of output.
    public func run(onLine: @escaping @Sendable (String) -> Void) async throws -> Result {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let dir = currentDirectory { process.currentDirectoryURL = dir }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        if let logFile {
            _ = FileManager.default.createFile(atPath: logFile.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: logFile)
            logHandle?.seekToEndOfFile()
            writeLog("$ \(commandLine)\n")
        }

        let reader = pipe.fileHandleForReading
        // Read on a dedicated thread until EOF so no output is lost or
        // delivered after we report the exit.
        let readerDone = DispatchSemaphore(value: 0)
        let readThread = Thread { [weak self] in
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                self?.consume(data, onLine: onLine)
            }
            readerDone.signal()
        }
        readThread.name = "ProcessRunner.read"

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            process.terminationHandler = { [weak self] p in
                // Give the reader a moment to hit EOF (a grandchild might keep the pipe open).
                _ = readerDone.wait(timeout: .now() + 3)
                guard let self else { return }
                self.flushRemainder(onLine: onLine)
                let (out, wasCancelled): (String, Bool) = self.lock.sync { (self.collected, self.cancelled) }
                self.writeLog("[exit \(p.terminationStatus)]\n")
                try? self.logHandle?.close()
                cont.resume(returning: Result(exitCode: p.terminationStatus, output: out, wasCancelled: wasCancelled))
            }
            do {
                try process.run()
                readThread.start()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
    }

    /// Asks the process to stop (SIGINT first so tools can clean up, then SIGTERM, then SIGKILL).
    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        guard process.isRunning else { return }
        process.interrupt()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { p.terminate() }
        }
        // SIGKILL can't be blocked or ignored — last resort.
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    private func consume(_ data: Data, onLine: @Sendable (String) -> Void) {
        writeLogData(data)
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            let line = String(decoding: lineData, as: UTF8.self)
            if !line.isEmpty { lines.append(line) }
        }
        for l in lines { collected += l + "\n" }
        // Keep the in-memory transcript bounded (the full log is on disk).
        if collected.utf8.count > 4_000_000 { collected = String(collected.suffix(2_000_000)) }
        lock.unlock()
        lines.forEach(onLine)
    }

    private func flushRemainder(onLine: @Sendable (String) -> Void) {
        lock.lock()
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        if !line.isEmpty { collected += line + "\n" }
        lock.unlock()
        if !line.isEmpty { onLine(line) }
    }

    private func writeLog(_ s: String) { writeLogData(Data(s.utf8)) }
    private func writeLogData(_ d: Data) {
        guard let h = logHandle else { return }
        h.write(d)
    }
}

public enum ToolEnvironment {
    /// PATH that finds Homebrew installs on Apple Silicon and Intel Macs, plus
    /// `make install` locations used by the guide (idevicerestore → /usr/local/bin).
    public static let searchPaths = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    public static var standard: [String: String] {
        var env = ProcessInfo.processInfo.environment
        var paths = searchPaths
        paths.insert(ToolLocator.userToolsDirectory.path, at: 0)
        if let bundled = ToolLocator.bundledToolsDirectory?.path { paths.insert(bundled, at: 0) }
        env["PATH"] = paths.joined(separator: ":")
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }
}

/// A one-shot signal that async code can wait on (safe if signalled first).
public final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func signal() {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        let w = waiters
        waiters = []
        lock.unlock()
        w.forEach { $0.resume() }
    }

    public func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }

    public var isSignalled: Bool { lock.lock(); defer { lock.unlock() }; return fired }
}

extension NSLock {
    /// Runs `body` while holding the lock (usable from async code).
    @inline(__always)
    public func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
