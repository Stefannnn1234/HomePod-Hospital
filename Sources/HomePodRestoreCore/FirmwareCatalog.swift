import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HomePodModel {
    public static let identifier = "AudioAccessory1,1"
    /// Apple TV HD — its restore ramdisk is the donor for building HomePod IPSWs.
    public static let donorIdentifier = "AppleTV5,3"
}

/// One firmware entry from api.ipsw.me v4.
public struct IPSWMeFirmware: Codable, Hashable, Identifiable, Sendable {
    public let identifier: String
    public let buildid: String
    public let version: String
    public let url: URL
    public let filesize: Int64?
    public let signed: Bool
    public let releasedate: String?
    public let prerequisitebuildid: String?
    public let releasetype: String?
    public let sha256sum: String?

    public var id: String { url.absoluteString + buildid }

    /// HomePod OTAs report versions like "9.9.18.3" — show "18.3".
    public var displayVersion: String {
        version.hasPrefix("9.9.") ? String(version.dropFirst(4)) : version
    }

    public var isFullOTA: Bool { (prerequisitebuildid ?? "").isEmpty }
    public var isBeta: Bool { (releasetype ?? "").localizedCaseInsensitiveContains("beta") }
}

struct IPSWMeDeviceResponse: Codable {
    let name: String?
    let identifier: String?
    let firmwares: [IPSWMeFirmware]
}

/// A HomePod software version you can build an IPSW from, with the matching
/// Apple TV donor (if ipsw.me has one).
public struct BuildableRelease: Identifiable, Hashable, Sendable {
    public var id: String { ota.buildid }
    public let ota: IPSWMeFirmware
    public let donor: IPSWMeFirmware?
    public var version: String { ota.displayVersion }
    public var build: String { ota.buildid }
    public var isSigned: Bool { ota.signed }
}

public enum FirmwareCatalog {
    public static func fetch(_ identifier: String, type: String, session: URLSession = .shared) async throws -> [IPSWMeFirmware] {
        var req = URLRequest(url: Links.ipswMeDevice(identifier, type: type))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> [IPSWMeFirmware] {
        try JSONDecoder().decode(IPSWMeDeviceResponse.self, from: data).firmwares
    }

    /// Picks one full OTA per build (the largest — it has the full ramdisk, per
    /// the guide), drops betas, newest first, and pairs each with the Apple TV
    /// IPSW that has the same build number.
    public static func buildableReleases(otas: [IPSWMeFirmware], donors: [IPSWMeFirmware]) -> [BuildableRelease] {
        var bestByBuild: [String: IPSWMeFirmware] = [:]
        for f in otas where f.isFullOTA && !f.isBeta {
            if let cur = bestByBuild[f.buildid] {
                if (f.filesize ?? 0) > (cur.filesize ?? 0) { bestByBuild[f.buildid] = f }
            } else {
                bestByBuild[f.buildid] = f
            }
        }
        let donorByBuild = Dictionary(donors.map { ($0.buildid, $0) }, uniquingKeysWith: { a, _ in a })
        let donorByVersion = Dictionary(donors.map { ($0.version, $0) }, uniquingKeysWith: { a, _ in a })
        return bestByBuild.values
            .map { ota in
                BuildableRelease(ota: ota, donor: donorByBuild[ota.buildid] ?? donorByVersion[ota.displayVersion])
            }
            .sorted { compareVersions($0.version, $1.version) == .orderedDescending }
    }

    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Whether Apple currently signs a given HomePod build (via ipsw.me).
    public static func isSigned(build: String, in otas: [IPSWMeFirmware]) -> Bool? {
        let matches = otas.filter { $0.buildid == build }
        guard !matches.isEmpty else { return nil }
        return matches.contains { $0.signed }
    }
}

/// Remote catalog hosted at nicsfix.com/ipsw/manifest.json. Lets Nic change the
/// recommended firmware, warnings and links without shipping a new app.
public struct PrebuiltManifest: Codable, Sendable {
    public struct Entry: Codable, Hashable, Identifiable, Sendable {
        public let version: String
        public let build: String
        public let url: URL
        public let size: Int64?
        public let sha256: String?
        public let recommended: Bool?
        /// Shown under the entry, e.g. "Restoring 26.0.1 has caused boot loops".
        public let note: String?
        public var id: String { build }
    }

    public let schema: Int?
    public let firmwares: [Entry]
    /// Shown as a banner at the top of the app when set.
    public let announcement: String?
    public let discordURL: URL?
    public let donateURL: URL?
    public let minimumAppVersion: String?
    public let latestAppVersion: String?
    public let appDownloadURL: URL?

    public var recommended: Entry? { firmwares.first { $0.recommended == true } ?? firmwares.first }

    /// Used when nicsfix.com can't be reached.
    public static let fallback = PrebuiltManifest(
        schema: 1,
        firmwares: [
            Entry(version: "18.3", build: "22K557", url: Links.fallbackPrebuiltIPSW, size: 3_431_162_133,
                  sha256: "2e8d1e70dc0ab55be2864e8630553e0dedd3eb000d406382f642b62f9ed932dd",
                  recommended: true,
                  note: "Recommended. After restoring, let the HomePod update itself from the Home app."),
        ],
        announcement: nil, discordURL: nil, donateURL: nil,
        minimumAppVersion: nil, latestAppVersion: nil, appDownloadURL: nil)

    public static func fetch(session: URLSession = .shared) async -> PrebuiltManifest {
        var req = URLRequest(url: Links.manifest)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let m = try? JSONDecoder().decode(PrebuiltManifest.self, from: data),
              !m.firmwares.isEmpty else {
            return .fallback
        }
        return m
    }
}
