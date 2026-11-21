import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds a restorable HomePod .ipsw with tihmstar's makeipsw.sh:
///   1. download makeipsw.sh + firmware_keys.zip
///   2. download the full HomePod OTA (resumable)
///   3. download just BuildManifest.plist + the restore ramdisk from the
///      Apple TV HD IPSW (~100 MB instead of ~5 GB)
///   4. run makeipsw.sh with administrator privileges (it mounts disk images)
public final class IPSWBuilder: @unchecked Sendable {
    public enum Stage: Int, CaseIterable, Comparable, Sendable {
        case checking, downloadingScript, downloadingOTA, downloadingDonor, building, done
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
        public var title: String {
            switch self {
            case .checking: return "Checking your Mac"
            case .downloadingScript: return "Downloading build script & keys"
            case .downloadingOTA: return "Downloading HomePod software from Apple"
            case .downloadingDonor: return "Downloading Apple TV restore files"
            case .building: return "Building the .ipsw"
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
            self.stage = stage
            self.progress = progress
            self.detail = detail
            self.logLine = logLine
        }
    }

    public enum Failure: Error, LocalizedError {
        case missingTools([Tool])
        case lowDiskSpace(needed: Int64, available: Int64)
        case noDonor
        case donorRamdiskNotFound
        case cancelledByUser
        case buildFailed(code: Int, lastLines: String)

        public var errorDescription: String? {
            switch self {
            case .missingTools(let t):
                return "These tools are needed to build firmware but aren't installed: \(t.map(\.rawValue).joined(separator: ", ")). Open Setup → Install tools (builder)."
            case .lowDiskSpace(let n, let a):
                return "Building needs about \(ByteFormat.string(n)) of free space, but only \(ByteFormat.string(a)) is available."
            case .noDonor:
                return "ipsw.me doesn't list an Apple TV HD (AppleTV5,3) IPSW for this build, so it can't be built automatically."
            case .donorRamdiskNotFound:
                return "Couldn't find the restore ramdisk inside the Apple TV IPSW."
            case .cancelledByUser:
                return "The administrator password prompt was cancelled."
            case .buildFailed(let code, let last):
                return "makeipsw.sh failed (exit \(code)).\n\n\(last)"
            }
        }
    }

    public static let requiredFreeSpace: Int64 = 25 * 1_000_000_000

    public let release: BuildableRelease
    public let keepOTA: Bool
    private var cancelled = false
    private var runner: ProcessRunner?
    private var downloader: FileDownloader?

    public init(release: BuildableRelease, keepOTA: Bool = false) {
        self.release = release
        self.keepOTA = keepOTA
    }

    /// makeipsw.sh doesn't quote its arguments, so the work folder must not contain spaces.
    public static var workDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let preferred = caches.appendingPathComponent("HomePodRestore/build", isDirectory: true)
        if !preferred.path.contains(" ") { return preferred }
        return URL(fileURLWithPath: "/Users/Shared/HomePodRestoreBuild", isDirectory: true)
    }

    public func cancel() {
        cancelled = true
        downloader?.cancel()
        runner?.cancel()
    }

    /// Runs the whole build. Returns the finished .ipsw (in the Firmware folder).
    public func run(update: @escaping @Sendable (Update) -> Void) async throws -> URL {
        let work = Self.workDirectory
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        AppPaths.ensure()

        // 1. Checks
        update(Update(stage: .checking, progress: nil, detail: "Looking for build tools…"))
        let missing = Tool.allCases.filter { $0.isRequiredForBuild && ToolLocator.locate($0) == nil }
        guard missing.isEmpty else { throw Failure.missingTools(missing) }
        if let free = AppPaths.freeSpace(at: work), free < Self.requiredFreeSpace {
            throw Failure.lowDiskSpace(needed: Self.requiredFreeSpace, available: free)
        }
        guard let donor = release.donor else { throw Failure.noDonor }

        // 2. Script + keys
        update(Update(stage: .downloadingScript, progress: nil, detail: "makeipsw.sh from tihmstar/homepodstuff"))
        let script = work.appendingPathComponent("makeipsw.sh")
        let keys = work.appendingPathComponent("firmware_keys.zip")
        try await smallDownload(Links.makeipswScript, to: script)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try await smallDownload(Links.firmwareKeysZip, to: keys)
        let keysHaveBuild = await zipContainsBuild(keys, build: release.build)

        // 3. OTA (resumable)
        let ota = work.appendingPathComponent("ota-\(release.build).zip")
        if !(await isCompleteZip(ota)) {
            let d = FileDownloader(); downloader = d
            _ = try await d.download(release.ota.url, to: ota) { p in
                update(Update(stage: .downloadingOTA, progress: p.fraction, detail: ByteFormat.progress(p)))
            }
        }
        try checkCancelled()

        // 4. Donor: only the files makeipsw.sh reads
        let donorZip = work.appendingPathComponent("donor-\(donor.buildid).ipsw")
        if !(await isCompleteZip(donorZip)) {
            try await buildMiniDonor(from: donor.url, to: donorZip) { done, total in
                let p = DownloadProgress(received: done, total: total, bytesPerSecond: nil)
                update(Update(stage: .downloadingDonor, progress: p.fraction, detail: ByteFormat.progress(p) + " (instead of the full 5 GB)"))
            }
        }
        try checkCancelled()

        // 5. Build
        let out = work.appendingPathComponent("HomePod-\(release.version)-\(release.build).ipsw")
        try? fm.removeItem(at: out)
        let log = AppPaths.logs.appendingPathComponent("build-\(release.build)-\(Self.stamp()).log")
        update(Update(stage: .building, progress: nil, detail: "Waiting for your password…"))
        try await runMakeIPSW(script: script, ota: ota, donor: donorZip, output: out,
                              keys: keysHaveBuild ? keys : nil, log: log, work: work, update: update)

        // 6. Move into the library
        let final = AppPaths.firmware.appendingPathComponent(out.lastPathComponent)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: out, to: final)
        if !keepOTA { try? fm.removeItem(at: ota) }
        update(Update(stage: .done, progress: 1, detail: final.lastPathComponent))
        return final
    }

    // MARK: - Steps

    private func checkCancelled() throws { if cancelled { throw DownloadError.cancelled } }

    private func smallDownload(_ url: URL, to dest: URL) async throws {
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw DownloadError.http(http.statusCode) }
        try data.write(to: dest, options: .atomic)
    }

    private func isCompleteZip(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? await ZipDirectory.read(from: LocalFileSource(url: url))) != nil
    }

    private func zipContainsBuild(_ url: URL, build: String) async -> Bool {
        guard let dir = try? await ZipDirectory.read(from: LocalFileSource(url: url)) else { return false }
        return dir.entries.contains { $0.name.hasSuffix("/\(build)") && !$0.name.hasPrefix("__MACOSX") }
    }

    /// Copies BuildManifest.plist and the "Customer Erase Install" restore
    /// ramdisk out of the remote Apple TV IPSW into a small local zip.
    func buildMiniDonor(from url: URL, to dest: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let src = HTTPRangeSource(url: url)
        let dir = try await ZipDirectory.read(from: src)
        guard let bm = dir.entry(named: "BuildManifest.plist") else { throw ZipError.entryNotFound("BuildManifest.plist") }
        let manifest = try await ZipDirectory.contents(of: bm, in: src)
        guard let ramdiskPath = Self.donorRamdiskPath(manifest), let rd = dir.entry(named: ramdiskPath) else {
            throw Failure.donorRamdiskNotFound
        }
        let total = Int64(bm.compressedSize + rd.compressedSize)
        let partial = dest.appendingPathExtension("partial")
        let writer = try ZipCopyWriter(url: partial)
        var done: Int64 = 0
        for entry in [bm, rd] {
            let offset = try await ZipDirectory.dataOffset(of: entry, in: src)
            try await writer.add(entry) { append in
                var pos: UInt64 = 0
                let chunk: UInt64 = 8 * 1024 * 1024
                while pos < entry.compressedSize {
                    try self.checkCancelled()
                    let len = Int(min(chunk, entry.compressedSize - pos))
                    var data = Data()
                    var attempt = 0
                    while true {
                        do { data = try await src.read(offset: offset + pos, length: len); break }
                        catch { attempt += 1; if attempt >= 4 { throw error }; try await Task.sleep(nanoseconds: 2_000_000_000) }
                    }
                    guard data.count == len else { throw ZipError.truncated }
                    append(data)
                    pos += UInt64(len)
                    done += Int64(len)
                    progress(done, total)
                }
            }
        }
        try writer.finish()
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: partial, to: dest)
    }

    /// Same selection makeipsw.sh does: the identity whose Variant is
    /// "Customer Erase Install (IPSW)" → Manifest.RestoreRamDisk.Info.Path
    public static func donorRamdiskPath(_ manifest: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: manifest, format: nil) as? [String: Any],
              let ids = plist["BuildIdentities"] as? [[String: Any]] else { return nil }
        for id in ids {
            let variant = (id["Info"] as? [String: Any])?["Variant"] as? String ?? ""
            if variant.contains("Customer Erase Install (IPSW)") {
                return (((id["Manifest"] as? [String: Any])?["RestoreRamDisk"] as? [String: Any])?["Info"] as? [String: Any])?["Path"] as? String
            }
        }
        return nil
    }

    private func runMakeIPSW(script: URL, ota: URL, donor: URL, output: URL, keys: URL?, log: URL, work: URL,
                             update: @escaping @Sendable (Update) -> Void) async throws {
        let fm = FileManager.default
        let exitFile = work.appendingPathComponent("exitcode")
        try? fm.removeItem(at: exitFile)
        _ = fm.createFile(atPath: log.path, contents: nil)

        let runScript = work.appendingPathComponent("run-build.sh")
        try Self.makeRunScript(script: script, ota: ota, donor: donor, output: output, keys: keys,
                               log: log, exitFile: exitFile, uid: getuid(), gid: getgid())
            .write(to: runScript, atomically: true, encoding: .utf8)

        let prompt = "HomePod Hospital needs your password to build the firmware. (makeipsw.sh creates and mounts disk images.)"
        let apple = "do shell script \"/bin/bash \" & quoted form of \"\(runScript.path)\" with administrator privileges with prompt \"\(prompt)\""
        let r = ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", apple])
        runner = r

        // Follow the log while the privileged script runs.
        let tail = Task {
            var offset: UInt64 = 0
            var progress = BuildLogProgress()
            var pendingPartial = ""
            while !Task.isCancelled {
                if let h = try? FileHandle(forReadingFrom: log) {
                    try? h.seek(toOffset: offset)
                    let data = h.readDataToEndOfFile()
                    try? h.close()
                    offset += UInt64(data.count)
                    if !data.isEmpty {
                        let text = pendingPartial + String(decoding: data, as: UTF8.self)
                        var lines = text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                        pendingPartial = lines.removeLast()
                        for l in lines where !l.isEmpty {
                            progress.consume(l)
                            update(Update(stage: .building, progress: progress.fraction, detail: progress.step, logLine: l))
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        let result = try await r.run(onLine: { _ in })
        try? await Task.sleep(nanoseconds: 600_000_000)
        tail.cancel()

        if result.exitCode != 0 && result.output.contains("-128") { throw Failure.cancelledByUser }
        let code = Int((try? String(contentsOf: exitFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
        let ok = code == 0 && fm.fileExists(atPath: output.path)
        if !ok {
            let last = ((try? String(contentsOf: log, encoding: .utf8)) ?? result.output)
                .split(separator: "\n").suffix(15).joined(separator: "\n")
            throw Failure.buildFailed(code: code, lastLines: last)
        }
    }

    static func makeRunScript(script: URL, ota: URL, donor: URL, output: URL, keys: URL?, log: URL, exitFile: URL, uid: uid_t, gid: gid_t) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var args = [q(ota.path), q(donor.path), q(output.path)]
        if let keys { args.append(q(keys.path)) }
        return """
        #!/bin/bash
        # Generated by HomePod Hospital. Runs tihmstar's makeipsw.sh as root.
        export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        cd \(q(script.deletingLastPathComponent().path)) || exit 1
        /bin/bash \(q(script.path)) \(args.joined(separator: " ")) > \(q(log.path)) 2>&1
        code=$?
        echo "$code" > \(q(exitFile.path))
        # Clean up makeipsw's temp folder if it was left behind (it is ~10 GB).
        tmp=$(grep -m1 '^tmpdir=' \(q(log.path)) | cut -d= -f2-)
        case "$tmp" in /tmp/homepodtmp*|/private/tmp/homepodtmp*) rm -rf "$tmp" ;; esac
        chown \(uid):\(gid) \(q(output.path)) \(q(log.path)) \(q(exitFile.path)) 2>/dev/null
        exit 0
        """
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// Estimates build progress from makeipsw.sh's output.
public struct BuildLogProgress: Sendable {
    public private(set) var step = "Starting…"
    public private(set) var fraction: Double? = 0
    private var chunksSeen = 0

    public init() {}

    public mutating func consume(_ line: String) {
        let checkpoints: [(String, String, Double)] = [
            ("extracting ota", "Unpacking HomePod software", 0.02),
            ("Creating a rootfs", "Building root filesystem", 0.08),
            ("Creating a dmg", "Creating disk image", 0.30),
            ("Copying to", "Copying files into disk image", 0.33),
            ("Comparing image against mtree", "Checking files", 0.45),
            ("hdiutil convert", "Compressing disk image", 0.50),
            ("Done creating rootfs", "Root filesystem done", 0.62),
            ("Getting OTA ticket", "Getting signing ticket", 0.64),
            ("Deploying patched bootloaders", "Patching bootloaders", 0.70),
            ("Deploying patched kernel", "Patching kernel", 0.72),
            ("Extract donor", "Reading Apple TV restore files", 0.74),
            ("Patching asr", "Patching restore software", 0.77),
            ("Packing ramdisk", "Packing restore ramdisk", 0.80),
            ("Compressing IPSW", "Compressing .ipsw (takes a while)", 0.83),
            ("Done!!", "Done", 1.0),
        ]
        if line.hasPrefix("Extracting chunk") {
            chunksSeen += 1
            step = "Unpacking HomePod software (chunk \(chunksSeen))"
            fraction = min(0.08 + Double(chunksSeen) * 0.01, 0.29)
            return
        }
        for (needle, label, f) in checkpoints where line.contains(needle) {
            step = label
            fraction = max(fraction ?? 0, f)
        }
    }
}
