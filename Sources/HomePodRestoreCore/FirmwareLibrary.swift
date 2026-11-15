import Foundation

/// Where the app keeps its files.
public enum AppPaths {
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HomePod Restore", isDirectory: true)
    }
    public static var firmware: URL { support.appendingPathComponent("Firmware", isDirectory: true) }
    /// Shared idevicerestore cache (-C). The unpacked root filesystem lives
    /// here once so several HomePods can restore from it at the same time.
    public static var restoreCache: URL { support.appendingPathComponent("RestoreCache", isDirectory: true) }
    public static var buildWork: URL { support.appendingPathComponent("BuildWork", isDirectory: true) }
    public static var logs: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return lib.appendingPathComponent("Logs/HomePod Restore", isDirectory: true)
    }

    public static func ensure() {
        for d in [support, firmware, restoreCache, buildWork, logs] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    public static func freeSpace(at url: URL) -> Int64? {
        #if os(macOS)
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let v = values?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        return values?.volumeAvailableCapacity.map(Int64.init)
        #else
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
        #endif
    }
}

/// What's inside an .ipsw, read from its BuildManifest.plist.
public struct IPSWInfo: Codable, Hashable, Sendable {
    public let productVersion: String
    public let buildVersion: String
    public let supportedProductTypes: [String]
    /// Root filesystem path inside the archive (e.g. "myrootfs.dmg").
    public let osPath: String?
    public let osCompressed: Bool
    public let osUncompressedSize: UInt64?
    public let isCustomHomePodBuild: Bool

    public var isHomePod: Bool { supportedProductTypes.contains(HomePodModel.identifier) }
}

public enum IPSWInspector {
    public enum Failure: Error, LocalizedError {
        case notHomePod([String])
        case noManifest
        public var errorDescription: String? {
            switch self {
            case .notHomePod(let t): return "This firmware is for \(t.joined(separator: ", ")), not a 1st-gen HomePod (AudioAccessory1,1)."
            case .noManifest: return "This file doesn't look like an .ipsw (no BuildManifest.plist)."
            }
        }
    }

    public static func inspect(_ url: URL) async throws -> IPSWInfo {
        let src = LocalFileSource(url: url)
        let dir = try await ZipDirectory.read(from: src)
        guard let bm = dir.entry(named: "BuildManifest.plist") else { throw Failure.noManifest }
        let data = try await ZipDirectory.contents(of: bm, in: src)
        return try parse(manifest: data, directory: dir)
    }

    public static func parse(manifest data: Data, directory: ZipDirectory) throws -> IPSWInfo {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.noManifest
        }
        let version = plist["ProductVersion"] as? String ?? "?"
        let build = plist["ProductBuildVersion"] as? String ?? "?"
        let types = plist["SupportedProductTypes"] as? [String] ?? []
        let identities = plist["BuildIdentities"] as? [[String: Any]] ?? []
        let identity = identities.first { (($0["Info"] as? [String: Any])?["Variant"] as? String)?.contains("Erase") == true } ?? identities.first
        let manifest = identity?["Manifest"] as? [String: Any]
        let osPath = ((manifest?["OS"] as? [String: Any])?["Info"] as? [String: Any])?["Path"] as? String
        let osEntry = osPath.flatMap { directory.entry(named: $0) }
        return IPSWInfo(productVersion: version, buildVersion: build, supportedProductTypes: types,
                        osPath: osPath, osCompressed: !(osEntry?.isStored ?? true),
                        osUncompressedSize: osEntry?.uncompressedSize,
                        isCustomHomePodBuild: osPath == "myrootfs.dmg")
    }
}

/// A firmware file the user can restore with.
public struct FirmwareItem: Codable, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case prebuilt, built, imported }
    public var id: String { path }
    public var path: String
    public var info: IPSWInfo
    public var origin: Origin
    public var addedAt: Date
    public var url: URL { URL(fileURLWithPath: path) }
    public var displayName: String { "HomePod \(info.productVersion) (\(info.buildVersion))" }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Keeps track of downloaded / built / imported IPSWs.
public final class FirmwareLibrary: @unchecked Sendable {
    public private(set) var items: [FirmwareItem] = []
    private let indexURL: URL
    private let lock = NSLock()

    public init(directory: URL = AppPaths.support) {
        indexURL = directory.appendingPathComponent("firmware-index.json")
        load()
    }

    public func load() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.iso.decode([FirmwareItem].self, from: data) else { items = []; return }
        items = decoded.filter { $0.exists }
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(items) {
            try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    @discardableResult
    public func add(_ url: URL, origin: FirmwareItem.Origin) async throws -> FirmwareItem {
        let info = try await IPSWInspector.inspect(url)
        guard info.isHomePod else { throw IPSWInspector.Failure.notHomePod(info.supportedProductTypes) }
        let item = FirmwareItem(path: url.path, info: info, origin: origin, addedAt: Date())
        insert(item)
        return item
    }

    private func insert(_ item: FirmwareItem) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.path == item.path }
        items.insert(item, at: 0)
        save()
    }

    public func remove(_ item: FirmwareItem, deleteFile: Bool) {
        lock.lock()
        items.removeAll { $0.id == item.id }
        save()
        lock.unlock()
        if deleteFile {
            try? FileManager.default.removeItem(at: item.url)
            FilesystemCache.remove(for: item)
        }
    }

    public func item(forBuild build: String) -> FirmwareItem? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.info.buildVersion == build && $0.exists }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e }
}

/// Unpacks an IPSW's root filesystem once into idevicerestore's cache layout
/// (`<cache>/<ipsw name>/<os path>`). With the file already there, every
/// idevicerestore run prints "Using cached filesystem" and skips extraction —
/// which is what makes restoring several HomePods at once safe and fast.
public enum FilesystemCache {
    public static func cachedPath(for item: FirmwareItem, cacheDir: URL = AppPaths.restoreCache) -> URL? {
        guard let os = item.info.osPath else { return nil }
        var base = item.url.lastPathComponent
        if let dot = base.lastIndex(of: "."), base.index(after: dot) < base.endIndex, base[base.index(after: dot)].isLetter {
            base = String(base[..<dot])
        }
        return cacheDir.appendingPathComponent(base, isDirectory: true).appendingPathComponent(os)
    }

    public static func isReady(for item: FirmwareItem) -> Bool {
        guard item.info.osCompressed else { return true }  // stored entries are streamed directly
        guard let p = cachedPath(for: item), let expected = item.info.osUncompressedSize else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: p.path)[.size] as? NSNumber)?.uint64Value
        return size == expected
    }

    public static func remove(for item: FirmwareItem) {
        guard let p = cachedPath(for: item) else { return }
        try? FileManager.default.removeItem(at: p.deletingLastPathComponent())
    }

    /// Extracts the root filesystem with /usr/bin/unzip, reporting progress 0...1.
    public static func prepare(_ item: FirmwareItem, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if isReady(for: item) { onProgress(1); return }
        guard let dest = cachedPath(for: item), let os = item.info.osPath else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = dest.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        _ = fm.createFile(atPath: partial.path, contents: nil)

        let expected = Double(item.info.osUncompressedSize ?? 1)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", item.url.path, os]
        let out = try FileHandle(forWritingTo: partial)
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let exited = Latch()
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let monitor = Task {
            while !Task.isCancelled {
                let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.doubleValue ?? 0
                onProgress(min(size / expected, 0.999))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        await withTaskCancellationHandler {
            await exited.wait()
        } onCancel: {
            process.terminate()
        }
        monitor.cancel()
        try? out.close()
        guard process.terminationStatus == 0 else {
            try? fm.removeItem(at: partial)
            throw ZipError.truncated
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: partial, to: dest)
        guard isReady(for: item) else { throw ZipError.truncated }
        onProgress(1)
    }
}
