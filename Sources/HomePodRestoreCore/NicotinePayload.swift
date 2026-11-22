import Foundation

// MARK: - Nicotine payload: where the boot files come from
//
// A *payload* is a folder laid out like the Nicotine image folder
// (NicotineLayout: `img4/` with the five boot files, `homepod-config.sh`,
// `boot-linux.sh`) plus a `MANIFEST` that lists every file with its SHA-256.
//
// The app looks for one in this order (NicotinePayloadLocator.resolve):
//
//   1. a folder the user picked (a developer's image folder; it may have no
//      MANIFEST, and then nothing is verified: it works as it always did)
//   2. the payload built into the app: Contents/Resources/Nicotine/
//      (`BUNDLE_NICOTINE=1 ./scripts/build-app.sh`)
//   3. a payload imported into Application Support: …/HomePod Hospital/Nicotine/
//      ("Import Nicotine payload…" on the Nicotine page: a folder or a .zip)
//
// A payload with a MANIFEST is checked file by file before every boot. The
// 43 MB image is the one thing a download truncates, and a truncated image
// fails late, on the pod, where only the UART shows why.
//
// The payload is NOT part of this repository. See docs/nicotine-boot.md.

/// The `MANIFEST` of a distributable payload.
///
///     nicotine-payload 1
///     build=107
///     variant=public
///     created=2026-11-21T08:10:00Z
///     <sha256>  img4/iBSS.dev-hoolock.img4
///     …
///
/// Header lines are `key=value`; keys this version does not know are ignored.
public struct NicotineManifest: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// Lower-case hex, 64 characters.
        public let sha256: String
        /// Relative to the payload folder, "/" separated.
        public let path: String
        public init(sha256: String, path: String) { self.sha256 = sha256; self.path = path }
    }

    public static let fileName = "MANIFEST"
    public static let magic = "nicotine-payload 1"

    /// Every `key=value` header line, known or not.
    public var header: [String: String]
    public var entries: [Entry]

    public init(header: [String: String] = [:], entries: [Entry] = []) {
        self.header = header; self.entries = entries
    }

    /// The Nicotine build number ("107").
    public var build: String? { header["build"] }
    public var variant: String? { header["variant"] }
    public var created: String? { header["created"] }

    /// "build 107 (public)"
    public var summary: String {
        var text = build.map { "build \($0)" } ?? "unknown build"
        if let v = variant, !v.isEmpty { text += " (\(v))" }
        return text
    }

    /// A relative path that stays inside the payload folder.
    static func isSafe(relativePath p: String) -> Bool {
        if p.isEmpty || p.hasPrefix("/") || p.hasPrefix("~") || p.contains("\\") || p.contains("\0") { return false }
        for part in p.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }

    public static func parse(_ text: String) throws -> NicotineManifest {
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let first = lines.first, first == magic else {
            throw NicotineError.manifestInvalid("it doesn't start with \"\(magic)\"")
        }
        var manifest = NicotineManifest()
        var seen = Set<String>()
        for line in lines.dropFirst() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            // "<64 hex><spaces><path>": a file. Anything else with "=" is a header line.
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2, parts[0].count == 64,
               parts[0].allSatisfy({ $0.isHexDigit }) {
                var path = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                if path.hasPrefix("*") { path.removeFirst() }          // shasum's binary-mode marker
                if path.hasPrefix("./") { path.removeFirst(2) }
                guard isSafe(relativePath: path) else {
                    throw NicotineError.manifestInvalid("it names a file outside the payload: \(path)")
                }
                guard seen.insert(path).inserted else {
                    throw NicotineError.manifestInvalid("it lists \(path) twice")
                }
                manifest.entries.append(Entry(sha256: parts[0].lowercased(), path: path))
            } else if let eq = line.firstIndex(of: "="), eq != line.startIndex {
                manifest.header[String(line[..<eq])] = String(line[line.index(after: eq)...])
            } else {
                throw NicotineError.manifestInvalid("this line makes no sense: \(line.prefix(80))")
            }
        }
        guard !manifest.entries.isEmpty else { throw NicotineError.manifestInvalid("it lists no files") }
        return manifest
    }

    /// The MANIFEST in a payload folder; nil when the folder has none.
    public static func load(from root: URL) throws -> NicotineManifest? {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000,
              let text = String(data: data, encoding: .utf8) else {
            throw NicotineError.manifestInvalid("it can't be read")
        }
        return try parse(text)
    }
}

/// Where the payload in use came from.
public enum NicotinePayloadSource: String, Sendable, Equatable {
    /// A folder the user picked (or the developer's default image folder).
    case chosen
    /// Built into the app bundle.
    case bundled
    /// Imported into Application Support.
    case imported

    public var title: String {
        switch self {
        case .chosen: return "Your own folder"
        case .bundled: return "Built into this app"
        case .imported: return "Imported into this Mac"
        }
    }
}

/// A payload folder and how it was found.
public struct NicotinePayload: Sendable, Equatable {
    public let source: NicotinePayloadSource
    public let layout: NicotineLayout

    public init(source: NicotinePayloadSource, layout: NicotineLayout) {
        self.source = source; self.layout = layout
    }

    /// The MANIFEST, if the folder has a readable one (nil also when it is damaged;
    /// `verify()` is what reports damage).
    public var manifest: NicotineManifest? { try? NicotineManifest.load(from: layout.root) }

    /// Where homepod-config.sh must keep its backups for this payload, or nil
    /// for "next to the script" (its own default, `./config`).
    ///
    /// A payload inside the app bundle or in Application Support must not be
    /// written into: the bundle is signed (and may be read-only), and an
    /// imported payload is replaced wholesale by the next import. Their
    /// backups go to `…/HomePod Hospital/Nicotine Settings`.
    public func configDirectoryOverride(settingsDirectory: URL = NicotinePayloadLocator.settingsDirectory) -> URL? {
        source == .chosen ? nil : settingsDirectory
    }

    /// The folder the backups are in.
    public func configDirectory(settingsDirectory: URL = NicotinePayloadLocator.settingsDirectory) -> URL {
        configDirectoryOverride(settingsDirectory: settingsDirectory) ?? layout.configDir
    }

    /// Checks every file the MANIFEST lists. Returns the manifest, or nil when
    /// the folder has none (nothing to check against: a developer's folder).
    @discardableResult
    public func verify(onProgress: ((String) -> Void)? = nil) throws -> NicotineManifest? {
        try NicotinePayloadVerifier.verify(root: layout.root, onProgress: onProgress)
    }
}

public enum NicotinePayloadVerifier {
    /// The payload's boot files, relative to the payload folder. The iBSS/iBEC
    /// boot loaders are NOT here: they are built from Apple's release firmware
    /// by ReleaseIBootBuilder and sent from there.
    public static let requiredFiles = [
        "img4/RestoreDeviceTree_b238aap.img4",
        "img4/RestoreTrustCache.img4",
        "img4/RestoreKernelCache_m1n1-linux.img4",
    ]

    /// Verifies `root` against its MANIFEST: every listed file must be there
    /// with the listed SHA-256, and the five boot files must be listed.
    /// Returns nil when there is no MANIFEST.
    @discardableResult
    public static func verify(root: URL, onProgress: ((String) -> Void)? = nil) throws -> NicotineManifest? {
        guard let manifest = try NicotineManifest.load(from: root) else { return nil }
        let listed = Set(manifest.entries.map(\.path))
        for needed in requiredFiles where !listed.contains(needed) {
            throw NicotineError.manifestInvalid("it doesn't list \(needed)")
        }
        let fm = FileManager.default
        for entry in manifest.entries {
            let file = root.appendingPathComponent(entry.path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else {
                throw NicotineError.payloadFileMissing(entry.path)
            }
            onProgress?(entry.path)
            let actual = try NicotineHash.sha256Hex(of: file)
            guard actual == entry.sha256 else { throw NicotineError.checksumMismatch(file: entry.path) }
        }
        return manifest
    }
}

/// Finds the payload to use.
public enum NicotinePayloadLocator {
    /// `Contents/Resources/Nicotine` of the running app (whether or not it exists).
    public static func bundledRoot(resources: URL? = Bundle.main.resourceURL) -> URL? {
        resources?.appendingPathComponent("Nicotine", isDirectory: true)
    }

    /// `…/Application Support/HomePod Hospital/Nicotine` (the legacy support
    /// folder on a Mac that still uses it: AppPaths decides).
    public static var importedRoot: URL { AppPaths.support.appendingPathComponent("Nicotine", isDirectory: true) }

    /// Settings backups for a bundled or imported payload.
    public static var settingsDirectory: URL { AppPaths.support.appendingPathComponent("Nicotine Settings", isDirectory: true) }

    /// The first usable payload: the chosen folder if it exists (even when it
    /// is incomplete: the user picked it, so its problems are shown rather
    /// than silently skipped), else a complete bundled payload, else a
    /// complete imported one. When nothing is complete, the first candidate
    /// that at least exists is returned so the page can say what is missing.
    public static func resolve(chosen: URL?, bundled: URL?, imported: URL?) -> NicotinePayload? {
        if let chosen {
            let l = NicotineLayout(root: chosen)
            if l.folderExists { return NicotinePayload(source: .chosen, layout: l) }
        }
        let rest: [(NicotinePayloadSource, URL?)] = [(.bundled, bundled), (.imported, imported)]
        var firstExisting: NicotinePayload?
        for (source, url) in rest {
            guard let url else { continue }
            let l = NicotineLayout(root: url)
            guard l.folderExists else { continue }
            if l.isComplete { return NicotinePayload(source: source, layout: l) }
            if firstExisting == nil { firstExisting = NicotinePayload(source: source, layout: l) }
        }
        return firstExisting
    }

    /// `resolve` with the app's real locations.
    public static func current(chosenPath: String) -> NicotinePayload? {
        resolve(chosen: chosenPath.isEmpty ? nil : URL(fileURLWithPath: chosenPath, isDirectory: true),
                bundled: bundledRoot(), imported: importedRoot)
    }
}

// MARK: - Import

/// Installs a payload (a folder, or a .zip of one) into Application Support.
public enum NicotinePayloadImporter {
    /// Hosting a payload for download is the publisher's decision; no address
    /// is built in. Put the https URL of a `Nicotine-<build>.zip` (made by
    /// scripts/make-nicotine-payload.sh) here to enable "Download" later.
    /// Empty = the app never downloads a payload.
    public static let payloadDownloadURL = ""

    /// The folder that holds MANIFEST: `dir` itself, or its only subfolder
    /// (a zip made from a folder usually has that folder at the top).
    static func payloadRoot(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(NicotineManifest.fileName).path) { return dir }
        let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        let withManifest = items.filter { fm.fileExists(atPath: $0.appendingPathComponent(NicotineManifest.fileName).path) }
        return withManifest.count == 1 ? withManifest[0] : nil
    }

    /// Verifies the payload at `source` (a folder or a .zip) and installs
    /// exactly the files its MANIFEST lists into `destination`, replacing
    /// whatever payload was there. Nothing is changed unless everything checks out.
    @discardableResult
    public static func install(from source: URL,
                               to destination: URL = NicotinePayloadLocator.importedRoot,
                               unzip: URL = URL(fileURLWithPath: "/usr/bin/unzip")) async throws -> NicotineManifest {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw NicotineError.importFailed("\(source.lastPathComponent) isn't there.")
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let work = parent.appendingPathComponent(".nicotine-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. find the payload folder (unpacking a zip first)
        var folder = source
        if !isDir.boolValue {
            guard source.pathExtension.lowercased() == "zip" else {
                throw NicotineError.importFailed("Choose a payload folder or a .zip file.")
            }
            let unpacked = work.appendingPathComponent("unzipped", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let runner = ProcessRunner(executable: unzip, arguments: ["-q", "-o", source.path, "-d", unpacked.path])
            let result = try await runner.run(onLine: { _ in })
            guard result.exitCode == 0 else {
                throw NicotineError.importFailed("The .zip couldn't be unpacked (it may be an incomplete download).")
            }
            folder = unpacked
        }
        guard let root = payloadRoot(in: folder) else {
            throw NicotineError.importFailed("This isn't a Nicotine payload: there is no MANIFEST file in it.")
        }

        // 2. verify it where it is
        guard let manifest = try NicotinePayloadVerifier.verify(root: root) else {
            throw NicotineError.importFailed("This isn't a Nicotine payload: there is no MANIFEST file in it.")
        }

        // 3. copy exactly what the MANIFEST lists, then swap it in
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        for path in manifest.entries.map(\.path) + [NicotineManifest.fileName] {
            let to = staged.appendingPathComponent(path)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: root.appendingPathComponent(path), to: to)
        }
        // shell scripts must stay runnable whatever the zip tool did to their mode
        for entry in manifest.entries where entry.path.hasSuffix(".sh") {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.appendingPathComponent(entry.path).path)
        }
        try NicotinePayloadVerifier.verify(root: staged)        // the copy, once more

        let old = parent.appendingPathComponent(".nicotine-old-\(UUID().uuidString)", isDirectory: true)
        let hadOld = fm.fileExists(atPath: destination.path)
        if hadOld { try fm.moveItem(at: destination, to: old) }
        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            if hadOld { try? fm.moveItem(at: old, to: destination) }
            throw error
        }
        if hadOld { try? fm.removeItem(at: old) }
        return manifest
    }
}

// MARK: - SHA-256

public enum NicotineHash {
    /// SHA-256 of a file as lower-case hex. CryptoKit where there is one (the
    /// Mac); the plain implementation below elsewhere (Linux test runs).
    public static func sha256Hex(of url: URL) throws -> String {
        if let fast = try FileDownloader.sha256(of: url) { return fast.lowercased() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = PlainSHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalize()
    }

    /// SHA-256 of bytes in memory (the plain implementation; used by tests).
    public static func plainSHA256Hex(_ data: Data) -> String {
        var hasher = PlainSHA256()
        hasher.update(data)
        return hasher.finalize()
    }
}

/// FIPS 180-4 SHA-256, straightforward and slow; only used where CryptoKit is missing.
struct PlainSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        var buf = pending
        buf.append(contentsOf: data)
        var offset = 0
        while buf.count - offset >= 64 {
            Self.compress(&h, buf, offset)
            offset += 64
        }
        pending = Array(buf[offset...])
    }

    private static func compress(_ h: inout [UInt32], _ block: [UInt8], _ at: Int) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = at + 4 * i
            w[i] = UInt32(block[j]) << 24 | UInt32(block[j + 1]) << 16 | UInt32(block[j + 2]) << 8 | UInt32(block[j + 3])
        }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }

    mutating func finalize() -> String {
        let bits = length &* 8
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(shift)) & 0xff)) }
        var offset = 0
        while offset < tail.count {
            Self.compress(&h, tail, offset)
            offset += 64
        }
        pending = []
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
