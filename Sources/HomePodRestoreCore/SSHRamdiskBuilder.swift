import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds a shell-capable (SSH) ramdisk for the 1st-gen HomePod from the donor
/// Apple TV restore ramdisk — the piece that lets SysCfg be read/restored over a
/// shell instead of desoldering the NAND. It reuses the same donor source the
/// firmware builder already pulls from, extracts just the restore ramdisk, and
/// hands it to `build-ssh-ramdisk.sh` for the privileged disk-image surgery.
///
/// This is the AudioAccessory1,1 analogue of the community ssh-ramdisk scripts.
/// The genuinely-unproven bits (ramdisk decryption key, the SSH overlay payload,
/// and the boot arguments) are isolated and flagged, consistent with the
/// honest-assessment framing of the SysCfg recovery route.
public final class SSHRamdiskBuilder: @unchecked Sendable {
    public enum Stage: Int, CaseIterable, Comparable, Sendable {
        case checking, fetchingDonor, fetchingKeys, patching, done
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        public var title: String {
            switch self {
            case .checking: return "Checking tools"
            case .fetchingDonor: return "Downloading Apple TV restore ramdisk"
            case .fetchingKeys: return "Downloading firmware keys"
            case .patching: return "Building the SSH ramdisk"
            case .done: return "Done"
            }
        }
    }

    public struct Update: Sendable {
        public var stage: Stage
        public var progress: Double?
        public var detail: String
        public var logLine: String?
        public init(stage: Stage, progress: Double? = nil, detail: String, logLine: String? = nil) {
            self.stage = stage; self.progress = progress; self.detail = detail; self.logLine = logLine
        }
    }

    public enum Failure: Error, LocalizedError {
        case noDonor
        case missingTools([Tool])
        case scriptNotFound
        case overlayNotFound(URL)
        case donorRamdiskNotFound
        case cancelledByUser
        case patchFailed(lastLines: String)

        public var errorDescription: String? {
            switch self {
            case .noDonor: return "ipsw.me doesn't list an Apple TV HD donor for this build, so the SSH ramdisk can't be built automatically."
            case .missingTools(let t): return "These tools are needed but aren't installed: \(t.map(\.rawValue).joined(separator: ", ")). Open Setup → Install tools (builder)."
            case .scriptNotFound: return "build-ssh-ramdisk.sh wasn't found in the app bundle."
            case .overlayNotFound(let u): return "The SSH overlay (dropbear + host keys + launch item) wasn't found at \(u.path). Drop an arm64 overlay there — see the build-ssh-ramdisk.sh header (note B)."
            case .donorRamdiskNotFound: return "Couldn't find the restore ramdisk inside the Apple TV IPSW."
            case .cancelledByUser: return "The administrator password prompt was cancelled."
            case .patchFailed(let last): return "Building the SSH ramdisk failed.\n\n\(last)"
            }
        }
    }

    public let release: BuildableRelease
    private var cancelled = false
    private var runner: ProcessRunner?
    private var downloader: FileDownloader?

    public init(release: BuildableRelease) { self.release = release }

    /// Where a built SSH ramdisk is cached (one per build).
    public static func cachedRamdisk(forBuild build: String) -> URL {
        AppPaths.support.appendingPathComponent("SSHRamdisk/sshrd-\(build).img4")
    }

    /// A working img4tool. Prefer SSHRD_Script's self-contained copy, which is
    /// immune to the Homebrew libplist version churn that breaks the brew build.
    public static func resolveImg4tool() -> URL? {
        let fm = FileManager.default
        // Prefer the app-bundled copy (native, self-contained via dylibbundler).
        if let bundled = ToolLocator.bundledToolsDirectory?.appendingPathComponent("img4tool"),
           fm.isExecutableFile(atPath: bundled.path) { return bundled }
        // Then SSHRD_Script's self-contained copy (x86_64 / Rosetta).
        let sshrd = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("SSHRD_Script/Darwin/img4tool")
        if fm.isExecutableFile(atPath: sshrd.path) { return sshrd }
        // Finally whatever is on PATH (Homebrew — may need the libplist fix).
        return ToolLocator.locate(.img4tool)?.url
    }

    /// Overlay location the script expects (dropbear, host keys, launchd plist).
    public static var overlayDirectory: URL {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("ssh-ramdisk-overlay", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return AppPaths.support.appendingPathComponent("ssh-ramdisk-overlay", isDirectory: true)
    }

    public func cancel() {
        cancelled = true
        downloader?.cancel()
        runner?.cancel()
    }

    public func run(update: @escaping @Sendable (Update) -> Void) async throws -> URL {
        AppPaths.ensure()
        let fm = FileManager.default
        let out = Self.cachedRamdisk(forBuild: release.build)
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1. Preconditions
        update(Update(stage: .checking, detail: "Looking for tools and overlay…"))
        guard let img4tool = Self.resolveImg4tool() else { throw Failure.missingTools([.img4tool]) }
        guard let donor = release.donor else { throw Failure.noDonor }
        guard let script = Self.locateScript() else { throw Failure.scriptNotFound }
        let overlay = Self.overlayDirectory
        guard fm.fileExists(atPath: overlay.path) else { throw Failure.overlayNotFound(overlay) }

        let work = AppPaths.support.appendingPathComponent("SSHRamdisk/work-\(release.build)", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // 2. Donor restore ramdisk (only that entry, via HTTP range reads)
        update(Update(stage: .fetchingDonor, detail: "Reading the Apple TV IPSW directory…"))
        let ramdisk = work.appendingPathComponent("donor-ramdisk.im4p")
        try await fetchDonorRamdisk(from: donor.url, to: ramdisk) { done, total in
            let p = total > 0 ? Double(done) / Double(total) : nil
            update(Update(stage: .fetchingDonor, progress: p, detail: ByteFormat.string(done) + (total > 0 ? " / " + ByteFormat.string(total) : "")))
        }
        try checkCancelled()

        // 3. Firmware keys (for the decrypt step, if this build needs one)
        update(Update(stage: .fetchingKeys, detail: "firmware_keys.zip"))
        let keys = work.appendingPathComponent("firmware_keys.zip")
        try? await smallDownload(Links.firmwareKeysZip, to: keys)

        // 4. Privileged patch (mounts/creates disk images → needs admin)
        let log = AppPaths.logs.appendingPathComponent("sshrd-\(release.build)-\(IPSWBuilder.stamp()).log")
        update(Update(stage: .patching, detail: "Waiting for your password…"))
        try await runPatch(script: script, ramdisk: ramdisk, keys: keys, overlay: overlay,
                           out: out, work: work, log: log, img4tool: img4tool, update: update)

        update(Update(stage: .done, progress: 1, detail: out.lastPathComponent))
        return out
    }

    // MARK: - Steps

    private func checkCancelled() throws { if cancelled { throw Failure.cancelledByUser } }

    static func locateScript() -> URL? {
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("build-ssh-ramdisk.sh")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // Dev fallback: alongside the sources.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build-ssh-ramdisk.sh")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private func smallDownload(_ url: URL, to dest: URL) async throws {
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw DownloadError.http(http.statusCode) }
        try data.write(to: dest, options: .atomic)
    }

    /// Streams just the restore ramdisk entry out of the remote donor IPSW.
    func fetchDonorRamdisk(from url: URL, to dest: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let src = HTTPRangeSource(url: url)
        let dir = try await ZipDirectory.read(from: src)
        guard let bm = dir.entry(named: "BuildManifest.plist") else { throw ZipError.entryNotFound("BuildManifest.plist") }
        let manifest = try await ZipDirectory.contents(of: bm, in: src)
        guard let path = IPSWBuilder.donorRamdiskPath(manifest), let rd = dir.entry(named: path) else {
            throw Failure.donorRamdiskNotFound
        }
        progress(0, Int64(rd.uncompressedSize))
        let data = try await ZipDirectory.contents(of: rd, in: src)
        try data.write(to: dest, options: .atomic)
        progress(Int64(data.count), Int64(data.count))
    }

    private func runPatch(script: URL, ramdisk: URL, keys: URL, overlay: URL, out: URL, work: URL, log: URL,
                          img4tool: URL, update: @escaping @Sendable (Update) -> Void) async throws {
        let fm = FileManager.default
        let exitFile = work.appendingPathComponent("exitcode")
        try? fm.removeItem(at: exitFile)
        try? fm.removeItem(at: out)
        _ = fm.createFile(atPath: log.path, contents: nil)

        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let runScript = work.appendingPathComponent("run-sshrd.sh")
        let body = """
        #!/bin/bash
        export PATH="\(ToolEnvironment.searchPaths.joined(separator: ":")):\(ToolLocator.userToolsDirectory.path)"
        export IMG4TOOL=\(q(img4tool.path))
        /bin/bash \(q(script.path)) \(q(ramdisk.path)) \(q(keys.path)) \(q(overlay.path)) \(q(out.path)) \(q(log.path))
        echo $? > \(q(exitFile.path))
        chown \(getuid()):\(getgid()) \(q(out.path)) \(q(log.path)) \(q(exitFile.path)) 2>/dev/null
        exit 0
        """
        try body.write(to: runScript, atomically: true, encoding: .utf8)

        let prompt = "HomePod Restore needs your password to build the SSH ramdisk. (It mounts and creates disk images.)"
        let apple = "do shell script \"/bin/bash \" & quoted form of \"\(runScript.path)\" with administrator privileges with prompt \"\(prompt)\""
        let r = ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", apple])
        runner = r

        let tail = Task {
            var offset: UInt64 = 0
            while !Task.isCancelled {
                if let h = try? FileHandle(forReadingFrom: log) {
                    try? h.seek(toOffset: offset)
                    let data = h.readDataToEndOfFile()
                    try? h.close()
                    offset += UInt64(data.count)
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.isEmpty {
                        update(Update(stage: .patching, progress: nil, detail: String(line), logLine: String(line)))
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        let result = try await r.run(onLine: { _ in })
        try? await Task.sleep(nanoseconds: 500_000_000)
        tail.cancel()

        if result.exitCode != 0 && result.output.contains("-128") { throw Failure.cancelledByUser }
        let code = Int((try? String(contentsOf: exitFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
        let ok = code == 0 && fm.fileExists(atPath: out.path)
        if !ok {
            let last = ((try? String(contentsOf: log, encoding: .utf8)) ?? result.output)
                .split(separator: "\n").suffix(15).joined(separator: "\n")
            throw Failure.patchFailed(lastLines: last)
        }
    }
}
