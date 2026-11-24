import Foundation

/// The pod's panic-log region ("Apple PanicLog Media"), decoded.
///
/// XNU saves a panic behind an `embedded_panic_header` (osfmk/kern/debug.h in
/// Apple's open-source XNU), packed, little-endian:
///
///     0  u32 magic             0x46554E4B ("FUNK")
///     4  u32 crc
///     8  u32 version
///    12  u64 flags
///    20  u32 panic log offset  (from the start of the header)
///    24  u32 panic log length
///    28  u32 stackshot offset
///    32  u32 stackshot length
///    36  u32 other log offset
///    40  u32 other log length
///
/// When no header is found but the region holds panic text, the text is used
/// as it is.
public struct PanicLogReport: Equatable, Sendable {
    public enum Source: String, Sendable { case embeddedHeader, plainText }

    public static let magic: UInt32 = 0x4655_4E4B

    public let source: Source
    public let headerVersion: UInt32?
    public let flags: UInt64?
    /// The panic log itself.
    public let panicText: String
    /// Console output saved after the stackshot, if any.
    public let otherLog: String?
    /// The `panic(...)` line (or the first line), shortened for display.
    public let headline: String
    /// What the header flags say, in words.
    public let notes: [String]
    /// A stackshot was saved alongside (bytes).
    public let stackshotBytes: Int

    /// True when the region holds nothing (all 0x00 or all 0xFF): no panic saved.
    public static func isBlank(_ data: Data) -> Bool {
        guard let first = data.first, first == 0 || first == 0xFF else { return data.isEmpty }
        return data.allSatisfy { $0 == first }
    }

    /// nil when the region is blank or holds nothing recognisable.
    public static func decode(_ data: Data) -> PanicLogReport? {
        guard !isBlank(data) else { return nil }
        let b = [UInt8](data)
        if let report = decodeHeader(b) { return report }
        return decodePlainText(b)
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    /// The header is normally at offset 0; look further (4-byte aligned, first
    /// MB) in case the region has a container in front of it.
    static func decodeHeader(_ b: [UInt8]) -> PanicLogReport? {
        var start = 0
        let limit = min(b.count - 44, 1 << 20)
        while start <= limit {
            if u32(b, start) == magic, let r = decodeHeader(b, at: start) { return r }
            start += 4
        }
        return nil
    }

    static func decodeHeader(_ b: [UInt8], at h: Int) -> PanicLogReport? {
        let version = u32(b, h + 8)
        let flags = UInt64(u32(b, h + 12)) | UInt64(u32(b, h + 16)) << 32
        func slice(_ offsetField: Int, _ lengthField: Int) -> [UInt8]? {
            let off = Int(u32(b, h + offsetField)), len = Int(u32(b, h + lengthField))
            guard len > 0, off >= 44, h + off + len <= b.count else { return nil }
            return Array(b[(h + off)..<(h + off + len)])
        }
        guard let log = slice(20, 24) else { return nil }
        let text = Self.text(log)
        guard !text.isEmpty else { return nil }
        let stackshotLen = slice(28, 32)?.count ?? 0
        return PanicLogReport(source: .embeddedHeader, headerVersion: version, flags: flags,
                              panicText: text, otherLog: slice(36, 40).map(Self.text).flatMap { $0.isEmpty ? nil : $0 },
                              headline: headline(text), notes: notes(flags), stackshotBytes: stackshotLen)
    }

    static func decodePlainText(_ b: [UInt8]) -> PanicLogReport? {
        let text = Self.text(Array(b.prefix(2 << 20)))
        guard let r = text.range(of: "panic(") ?? text.range(of: "panic", options: .caseInsensitive) else { return nil }
        let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let body = String(text[lineStart...])
        return PanicLogReport(source: .plainText, headerVersion: nil, flags: nil, panicText: body, otherLog: nil,
                              headline: headline(body), notes: [], stackshotBytes: 0)
    }

    /// Printable text: NULs and 0xFF fill dropped, invalid UTF-8 replaced.
    static func text(_ bytes: [UInt8]) -> String {
        let kept = bytes.filter { $0 != 0 && $0 != 0xFF }
        return String(decoding: kept, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func headline(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.first { $0.contains("panic(") } ?? lines.first { !$0.isEmpty } ?? ""
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }

    /// Flag bits from XNU's debug.h (EMBEDDED_PANIC_HEADER_FLAG_*).
    static func notes(_ flags: UInt64) -> [String] {
        var out: [String] = []
        if flags & 0x40 != 0 { out.append("A second panic happened while the first was being saved (nested panic).") }
        if flags & 0x80 != 0 { out.append("The panic was forced by a hardware reset request.") }
        if flags & 0x100 != 0 { out.append("A coprocessor asked for the panic.") }
        return out
    }
}
