import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Something we can read byte ranges from: a local file or an HTTP URL that
/// supports Range requests. Lets us peek inside multi-GB IPSWs without
/// unpacking or downloading them.
public protocol ByteSource: Sendable {
    func size() async throws -> UInt64
    func read(offset: UInt64, length: Int) async throws -> Data
}

public enum ZipError: Error, LocalizedError {
    case notAZip
    case truncated
    case entryNotFound(String)
    case unsupported(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "This file isn't a valid .ipsw/.zip archive."
        case .truncated: return "The archive is incomplete (was the download interrupted?)."
        case .entryNotFound(let n): return "\(n) is missing from the archive."
        case .unsupported(let s): return "Unsupported archive feature: \(s)"
        case .http(let c): return "The server returned HTTP \(c)."
        }
    }
}

public struct LocalFileSource: ByteSource {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func size() async throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }
    public func read(offset: UInt64, length: Int) async throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: offset)
        return h.readData(ofLength: length)
    }
}

public struct HTTPRangeSource: ByteSource {
    public let url: URL
    public let session: URLSession
    public init(url: URL, session: URLSession = .shared) { self.url = url; self.session = session }

    public func size() async throws -> UInt64 {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ZipError.http(0) }
        guard http.statusCode == 200 else { throw ZipError.http(http.statusCode) }
        if let len = http.value(forHTTPHeaderField: "Content-Length"), let n = UInt64(len) { return n }
        if http.expectedContentLength > 0 { return UInt64(http.expectedContentLength) }
        throw ZipError.unsupported("server did not report a size")
    }

    public func read(offset: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var req = URLRequest(url: url)
        req.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ZipError.http(0) }
        guard http.statusCode == 206 else { throw ZipError.http(http.statusCode) }
        return data
    }
}

/// One file inside a zip.
public struct ZipEntry: Equatable, Sendable {
    public let name: String
    public let method: UInt16          // 0 = stored, 8 = deflate
    public let crc32: UInt32
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let localHeaderOffset: UInt64
    public let modTime: UInt16
    public let modDate: UInt16

    public var isStored: Bool { method == 0 }
}

/// Minimal ZIP / ZIP64 central-directory reader.
public struct ZipDirectory: Sendable {
    public let entries: [ZipEntry]

    public func entry(named name: String) -> ZipEntry? { entries.first { $0.name == name } }

    public static func read(from source: ByteSource) async throws -> ZipDirectory {
        let total = try await source.size()
        guard total >= 22 else { throw ZipError.notAZip }
        // EOCD is within the last 64 KiB + 22 bytes.
        let tailLen = Int(min(total, 65_557))
        let tailStart = total - UInt64(tailLen)
        let tail = try await source.read(offset: tailStart, length: tailLen)
        guard let eocdPos = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else { throw ZipError.notAZip }

        var cdCount = UInt64(tail.le16(eocdPos + 10))
        var cdSize = UInt64(tail.le32(eocdPos + 12))
        var cdOffset = UInt64(tail.le32(eocdPos + 16))

        // ZIP64?
        if cdCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            let locPos = eocdPos - 20
            guard locPos >= 0, tail.le32(locPos) == 0x0706_4B50 else { throw ZipError.unsupported("ZIP64 locator missing") }
            let z64Offset = tail.le64(locPos + 8)
            let z64 = try await source.read(offset: z64Offset, length: 56)
            guard z64.count >= 56, z64.le32(0) == 0x0606_4B50 else { throw ZipError.unsupported("bad ZIP64 record") }
            cdCount = z64.le64(32)
            cdSize = z64.le64(40)
            cdOffset = z64.le64(48)
        }
        guard cdOffset + cdSize <= total, cdSize < 64 * 1024 * 1024 else { throw ZipError.truncated }

        let cd = try await source.read(offset: cdOffset, length: Int(cdSize))
        guard cd.count == Int(cdSize) else { throw ZipError.truncated }
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(cdCount))
        var p = 0
        while p + 46 <= cd.count, cd.le32(p) == 0x0201_4B50 {
            let method = cd.le16(p + 10)
            let time = cd.le16(p + 12)
            let date = cd.le16(p + 14)
            let crc = cd.le32(p + 16)
            var csize = UInt64(cd.le32(p + 20))
            var usize = UInt64(cd.le32(p + 24))
            let nameLen = Int(cd.le16(p + 28))
            let extraLen = Int(cd.le16(p + 30))
            let commentLen = Int(cd.le16(p + 32))
            var lho = UInt64(cd.le32(p + 42))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw ZipError.truncated }
            let name = String(decoding: cd[cd.startIndex + p + 46 ..< cd.startIndex + p + 46 + nameLen], as: UTF8.self)
            // ZIP64 extra field
            var e = p + 46 + nameLen
            let eEnd = e + extraLen
            while e + 4 <= eEnd {
                let tag = cd.le16(e), sz = Int(cd.le16(e + 2))
                if tag == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF, q + 8 <= e + 4 + sz { usize = cd.le64(q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= e + 4 + sz { csize = cd.le64(q); q += 8 }
                    if lho == 0xFFFF_FFFF, q + 8 <= e + 4 + sz { lho = cd.le64(q); q += 8 }
                }
                e += 4 + sz
            }
            entries.append(ZipEntry(name: name, method: method, crc32: crc, compressedSize: csize,
                                    uncompressedSize: usize, localHeaderOffset: lho, modTime: time, modDate: date))
            p += 46 + nameLen + extraLen + commentLen
        }
        return ZipDirectory(entries: entries)
    }

    /// Offset of an entry's compressed data (after its local header).
    public static func dataOffset(of entry: ZipEntry, in source: ByteSource) async throws -> UInt64 {
        let lh = try await source.read(offset: entry.localHeaderOffset, length: 30)
        guard lh.count == 30, lh.le32(0) == 0x0403_4B50 else { throw ZipError.truncated }
        return entry.localHeaderOffset + 30 + UInt64(lh.le16(26)) + UInt64(lh.le16(28))
    }

    /// Raw (still compressed) bytes of an entry. Fine for small entries.
    public static func rawData(of entry: ZipEntry, in source: ByteSource) async throws -> Data {
        let off = try await dataOffset(of: entry, in: source)
        return try await source.read(offset: off, length: Int(entry.compressedSize))
    }

    /// Decompressed bytes of a (small) entry.
    public static func contents(of entry: ZipEntry, in source: ByteSource) async throws -> Data {
        let raw = try await rawData(of: entry, in: source)
        switch entry.method {
        case 0: return raw
        case 8: return try Inflate.raw(raw, expectedSize: Int(entry.uncompressedSize))
        default: throw ZipError.unsupported("compression method \(entry.method)")
        }
    }

    static func lastIndex(of sig: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= sig.count else { return nil }
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == sig[0] && bytes[i + 1] == sig[1] && bytes[i + 2] == sig[2] && bytes[i + 3] == sig[3] { return i }
            i -= 1
        }
        return nil
    }
}

public enum Inflate {
    public enum Failure: Error { case unavailable, failed }

    /// Raw DEFLATE (RFC 1951) decompression, as used inside zip files.
    public static func raw(_ data: Data, expectedSize: Int) throws -> Data {
        #if canImport(Darwin)
        // NSData's .zlib algorithm is raw DEFLATE.
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Failure.failed
        }
        #else
        throw Failure.unavailable
        #endif
    }
}

/// Writes a new zip by copying entries' already-compressed bytes verbatim.
/// Used to build a tiny "donor.ipsw" containing only the two files
/// makeipsw.sh needs from the 5 GB Apple TV IPSW.
public final class ZipCopyWriter {
    private let handle: FileHandle
    private var central = Data()
    private var count: UInt16 = 0
    private var offset: UInt64 = 0

    public init(url: URL) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    /// Adds an entry. `writeData` is called with a closure that appends
    /// compressed bytes; it must append exactly `entry.compressedSize` bytes.
    public func add(_ entry: ZipEntry, writeData: (_ append: (Data) -> Void) async throws -> Void) async throws {
        guard entry.compressedSize < 0xFFFF_FFFF, entry.uncompressedSize < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else {
            throw ZipError.unsupported("entry too large for a small zip")
        }
        let name = Data(entry.name.utf8)
        var lh = Data()
        lh.appendLE32(0x0403_4B50)
        lh.appendLE16(20)                   // version needed
        lh.appendLE16(0)                    // flags
        lh.appendLE16(entry.method)
        lh.appendLE16(entry.modTime)
        lh.appendLE16(entry.modDate)
        lh.appendLE32(entry.crc32)
        lh.appendLE32(UInt32(entry.compressedSize))
        lh.appendLE32(UInt32(entry.uncompressedSize))
        lh.appendLE16(UInt16(name.count))
        lh.appendLE16(0)
        lh.append(name)
        handle.write(lh)
        let headerOffset = offset
        offset += UInt64(lh.count)

        var written: UInt64 = 0
        try await writeData { chunk in
            self.handle.write(chunk)
            written += UInt64(chunk.count)
        }
        guard written == entry.compressedSize else { throw ZipError.truncated }
        offset += written

        var c = Data()
        c.appendLE32(0x0201_4B50)
        c.appendLE16(0x031E)                // made by: unix, 3.0
        c.appendLE16(20)
        c.appendLE16(0)
        c.appendLE16(entry.method)
        c.appendLE16(entry.modTime)
        c.appendLE16(entry.modDate)
        c.appendLE32(entry.crc32)
        c.appendLE32(UInt32(entry.compressedSize))
        c.appendLE32(UInt32(entry.uncompressedSize))
        c.appendLE16(UInt16(name.count))
        c.appendLE16(0); c.appendLE16(0); c.appendLE16(0); c.appendLE16(0)
        c.appendLE32(0o100644 << 16)        // external attrs: regular file 0644
        c.appendLE32(UInt32(headerOffset))
        c.append(name)
        central.append(c)
        count += 1
    }

    public func finish() throws {
        let cdOffset = offset
        handle.write(central)
        var eocd = Data()
        eocd.appendLE32(0x0605_4B50)
        eocd.appendLE16(0); eocd.appendLE16(0)
        eocd.appendLE16(count); eocd.appendLE16(count)
        eocd.appendLE32(UInt32(central.count))
        eocd.appendLE32(UInt32(cdOffset))
        eocd.appendLE16(0)
        handle.write(eocd)
        try handle.close()
    }
}

extension Data {
    func le16(_ i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }
    func le32(_ i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }
    func le64(_ i: Int) -> UInt64 { UInt64(le32(i)) | UInt64(le32(i + 4)) << 32 }
    mutating func appendLE16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func appendLE32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}
