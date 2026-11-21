import Foundation

// MARK: - Release boot loaders from Apple's own files
//
// By default Nicotine boots on a pair of Apple DEVELOPMENT boot loaders
// (iBoot-4076.30.43 from a prototype, patched by HoolockLinux's hBootPatcher).
// Those must not be handed out. The same job can be done with the RELEASE
// iBSS/iBEC inside Apple's audioOS 16.4 update (build 20L497), which anyone can
// download from Apple:
//
//   download (Apple CDN, ~1 MB) → decrypt on the HomePod (gaster, checkm8 DFU)
//   → patch (hBootPatcher: sig-check, IORVBAR, AES) → wrap as IMG4
//
// That pipeline is HoolockLinux's own tool (`remote_boot`), driven by
// `prep-release-iboot.sh` — the exact sequence proven by hand on the bench.
// This preparer only RUNS that script and collects its two output files; it
// does not re-implement the crypto. The booter then sends those files in place
// of the dev pair (NicotineBooter.Config.releaseIBoot), the way
// `IBOOT_DIR=… ./boot-linux.sh` does. See docs/nicotine-boot.md.
//
// The script needs, the first time on a Mac: Homebrew `ipsw` (>= 3.1.719),
// `libirecovery`, and `make` (macOS ships one too old for remote_boot), plus
// the Xcode command line tools and the HomePod in checkm8 DFU. The preparer
// surfaces what the script reports rather than guessing.

/// Produces `iBSS.img4` / `iBEC.img4` in a folder by running
/// `prep-release-iboot.sh`, streaming its output.
public final class ReleaseIBootPreparer: @unchecked Sendable {
    /// Where the two files should land. For a chosen image folder this is its
    /// own `release-iboot/` (so the plain `boot-linux.sh` finds them too); for a
    /// bundled or imported payload, a writable folder in Application Support.
    public let outputDir: URL
    public var bash: URL
    public var environment: [String: String]

    private var runner: ProcessRunner?
    private var cancelled = false

    public init(outputDir: URL, bash: URL = URL(fileURLWithPath: "/bin/bash"),
                environment: [String: String] = ToolEnvironment.standard) {
        self.outputDir = outputDir
        self.bash = bash
        self.environment = environment
    }

    public var iBSS: URL { outputDir.appendingPathComponent("iBSS.img4") }
    public var iBEC: URL { outputDir.appendingPathComponent("iBEC.img4") }
    public var isPrepared: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: iBSS.path) && fm.fileExists(atPath: iBEC.path)
    }

    public enum Failure: Error, LocalizedError {
        case scriptNotFound
        case cancelledByUser
        case prepFailed(lastLines: String)
        /// The script exited 0 but the two files aren't there.
        case noOutput

        public var errorDescription: String? {
            switch self {
            case .scriptNotFound:
                return "prep-release-iboot.sh wasn't found in the app bundle."
            case .cancelledByUser:
                return "Preparing the release boot loaders was stopped."
            case .noOutput:
                return "The script finished but didn't leave iBSS.img4 and iBEC.img4. See the log."
            case .prepFailed(let last):
                return "Preparing the release boot loaders failed.\n\n\(last)"
            }
        }
    }

    public func cancel() {
        cancelled = true
        runner?.cancel()
    }

    /// Finds the bundled script; a dev checkout keeps it in `scripts/`.
    public static func locateScript() -> URL? {
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("prep-release-iboot.sh")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/prep-release-iboot.sh")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// Runs the script. Returns the two boot loaders on success. One checkm8 at
    /// a time across the app, like every boot (the script pwns the pod).
    @discardableResult
    public func run(onLog: @escaping @Sendable (String) -> Void) async throws -> (iBSS: URL, iBEC: URL) {
        guard let script = Self.locateScript() else { throw Failure.scriptNotFound }
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var env = environment
        env["RELEASE_IBOOT_OUT"] = outputDir.path

        return try await UnlockCoordinator.shared.run {
            if self.cancelled { throw Failure.cancelledByUser }
            let recent = RingLog(limit: 20)
            let r = ProcessRunner(executable: self.bash, arguments: [script.path],
                                  environment: env, currentDirectory: self.outputDir)
            self.runner = r
            let result = try await withTaskCancellationHandler {
                try await r.run(onLine: { line in recent.add(line); onLog(line) })
            } onCancel: {
                r.cancel()
            }
            if result.wasCancelled || self.cancelled { throw Failure.cancelledByUser }
            guard result.exitCode == 0 else {
                throw Failure.prepFailed(lastLines: recent.text)
            }
            guard self.isPrepared else { throw Failure.noOutput }
            return (self.iBSS, self.iBEC)
        }
    }
}

/// The last N lines seen, for an error message. Thread-safe.
final class RingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func add(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(s)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
