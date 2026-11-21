import Foundation

/// The command-line tools the app drives.
public enum Tool: String, CaseIterable, Identifiable, Sendable {
    // Needed to restore
    case gaster
    case idevicerestore
    case irecovery
    // Needed only to build your own .ipsw
    case ra1nsn0w
    case img4tool
    case tsschecker
    case binrider
    case ldid

    public var id: String { rawValue }

    public var isRequiredForRestore: Bool {
        switch self {
        case .gaster, .idevicerestore: return true
        default: return false
        }
    }

    public var isRequiredForBuild: Bool {
        switch self {
        case .ra1nsn0w, .img4tool, .tsschecker, .binrider, .ldid: return true
        default: return false
        }
    }

    public var purpose: String {
        switch self {
        case .gaster: return "Unlocks the HomePod so it accepts the restore (checkm8)"
        case .idevicerestore: return "Sends the firmware to the HomePod"
        case .irecovery: return "Talks to HomePods in DFU / recovery mode (optional)"
        case .ra1nsn0w: return "Patches bootloaders and kernel (firmware builder)"
        case .img4tool: return "Packs Apple firmware images (firmware builder)"
        case .tsschecker: return "Fetches signing tickets (firmware builder)"
        case .binrider: return "Finds the asr patch location (firmware builder)"
        case .ldid: return "Re-signs patched binaries (firmware builder)"
        }
    }

    /// Homebrew formula that provides the tool (per the guide).
    public var brewFormula: String {
        switch self {
        case .gaster: return "gaster"
        case .idevicerestore: return "idevicerestore (built from source @ d2e1c4f)"
        case .irecovery: return "libirecovery"
        case .ra1nsn0w: return "ra1nsn0w"
        case .img4tool: return "img4tool"
        case .tsschecker: return "tsschecker"
        case .binrider: return "libpatchfinder"
        case .ldid: return "ldid-procursus"
        }
    }
}

public struct ToolStatus: Identifiable, Sendable {
    public var id: Tool { tool }
    public let tool: Tool
    public let path: URL?
    public let isBundled: Bool
    public let version: String?
    /// Problems that would likely break a restore (shown to the user in plain words).
    public let warning: String?

    public var isInstalled: Bool { path != nil }
}

public enum ToolLocator {
    /// Tools shipped inside the app: HomePod Hospital.app/Contents/Resources/bin
    public static var bundledToolsDirectory: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("bin", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        // build-app.sh records which CPU the bundled tools were built for.
        if let archs = try? String(contentsOf: dir.appendingPathComponent("ARCHS"), encoding: .utf8) {
            let list = archs.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            if !list.isEmpty && !list.contains(machineArchitecture) { return nil }
        }
        return dir
    }

    /// "arm64" or "x86_64" (the real hardware, even under Rosetta).
    public static var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        var ret: Int32 = 0
        var size = MemoryLayout<Int32>.size
        #if os(macOS)
        if sysctlbyname("sysctl.proc_translated", &ret, &size, nil, 0) == 0, ret == 1 { return "arm64" }
        #endif
        return "x86_64"
        #endif
    }

    /// The idevicerestore commit the guide pins. Other versions often fail with
    /// "Unable to get SHSH blobs" / "isn't eligible".
    public static let expectedIdevicerestoreCommit = "d2e1c4f"

    /// Helper tools the in-app installer builds (patched gaster):
    /// ~/Library/Application Support/HomePod Hospital/bin
    /// (or …/HomePod Restore/bin on installs that predate the rename, see AppPaths)
    public static var userToolsDirectory: URL { AppPaths.support.appendingPathComponent("bin", isDirectory: true) }

    public static func locate(_ tool: Tool) -> (url: URL, bundled: Bool)? {
        let fm = FileManager.default
        if let dir = bundledToolsDirectory {
            let u = dir.appendingPathComponent(tool.rawValue)
            if fm.isExecutableFile(atPath: u.path) { return (u, true) }
        }
        let user = userToolsDirectory.appendingPathComponent(tool.rawValue)
        if fm.isExecutableFile(atPath: user.path) { return (user, false) }
        for p in ToolEnvironment.searchPaths {
            let u = URL(fileURLWithPath: p).appendingPathComponent(tool.rawValue)
            if fm.isExecutableFile(atPath: u.path) { return (u, false) }
        }
        return nil
    }

    public static func status(of tool: Tool) async -> ToolStatus {
        guard let found = locate(tool) else {
            return ToolStatus(tool: tool, path: nil, isBundled: false, version: nil, warning: nil)
        }
        var version: String?
        var warning: String?
        switch tool {
        case .idevicerestore:
            version = await firstLine(found.url, ["-v"])
            if let v = version, !v.contains(expectedIdevicerestoreCommit) {
                warning = "This isn't the idevicerestore version the guide uses (\(expectedIdevicerestoreCommit)). Restores may fail with \"Unable to get SHSH blobs\". Use Setup → Install tools to fix."
            }
        case .gaster:
            let usage = await output(found.url, [])
            version = usage.contains("GASTER_ECID") ? "multi-HomePod build" : "standard build"
            if !usage.contains("GASTER_ECID") {
                warning = "This gaster can only unlock one HomePod at a time. Connect HomePods one by one."
            }
        case .irecovery:
            version = await firstLine(found.url, ["-V"])
        case .tsschecker, .img4tool, .ra1nsn0w:
            version = await firstLine(found.url, ["--version"])
        default:
            version = nil
        }
        return ToolStatus(tool: tool, path: found.url, isBundled: found.bundled, version: version, warning: warning)
    }

    /// True if the gaster we'd use understands GASTER_ECID (our patched build).
    public static func gasterSupportsECID() async -> Bool {
        guard let g = locate(.gaster) else { return false }
        return await output(g.url, []).contains("GASTER_ECID")
    }

    static func output(_ url: URL, _ args: [String], timeout: TimeInterval = 5) async -> String {
        let runner = ProcessRunner(executable: url, arguments: args)
        let task = Task { try? await runner.run(onLine: { _ in }) }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            runner.cancel()
        }
        let r = await task.value
        timer.cancel()
        return r?.output ?? ""
    }

    static func firstLine(_ url: URL, _ args: [String]) async -> String? {
        let out = await output(url, args)
        return out.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}
