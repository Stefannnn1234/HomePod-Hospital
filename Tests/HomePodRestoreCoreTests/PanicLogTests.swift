import XCTest
@testable import HomePodRestoreCore

final class PanicLogTests: XCTestCase {
    /// An embedded_panic_header followed by its panic log and other log,
    /// padded out like the media region.
    static func region(panic: String, other: String = "", flags: UInt64 = 0, leading: Int = 0) -> Data {
        var d = Data(count: leading)
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let p = Array(panic.utf8), o = Array(other.utf8)
        let headerSize = 64
        put32(PanicLogReport.magic); put32(0); put32(2)
        put32(UInt32(flags & 0xFFFF_FFFF)); put32(UInt32(flags >> 32))
        put32(UInt32(headerSize)); put32(UInt32(p.count))
        put32(0); put32(0)
        put32(o.isEmpty ? 0 : UInt32(headerSize + p.count)); put32(UInt32(o.count))
        d.append(Data(count: leading + headerSize - d.count))
        d.append(contentsOf: p); d.append(contentsOf: o)
        d.append(Data(repeating: 0, count: 4096))
        return d
    }

    func testDecodesEmbeddedHeader() throws {
        let panic = "Debugger message: panic\npanic(cpu 0 caller 0xfffffff007123456): \"SEP ROM boot panic\"\nOS version: 22K557\n"
        let r = try XCTUnwrap(PanicLogReport.decode(Self.region(panic: panic, other: "late console line", flags: 0x40)))
        XCTAssertEqual(r.source, .embeddedHeader)
        XCTAssertEqual(r.headerVersion, 2)
        XCTAssertEqual(r.headline, "panic(cpu 0 caller 0xfffffff007123456): \"SEP ROM boot panic\"")
        XCTAssertTrue(r.panicText.hasSuffix("OS version: 22K557"))
        XCTAssertEqual(r.otherLog, "late console line")
        XCTAssertEqual(r.notes.count, 1)
    }

    func testFindsHeaderAfterAContainer() throws {
        let r = try XCTUnwrap(PanicLogReport.decode(Self.region(panic: "panic(cpu 1 caller 0x0): \"x\"", leading: 512)))
        XCTAssertEqual(r.source, .embeddedHeader)
    }

    func testBlankAndPlainText() throws {
        XCTAssertNil(PanicLogReport.decode(Data(count: 8192)))
        XCTAssertNil(PanicLogReport.decode(Data(repeating: 0xFF, count: 8192)))
        XCTAssertNil(PanicLogReport.decode(Data("nothing to see here".utf8) + Data(count: 100)))
        var plain = Data(count: 32)
        plain.append(Data("boot log\npanic(cpu 0 caller 0x1): \"Kernel data abort\"\nmore".utf8))
        let r = try XCTUnwrap(PanicLogReport.decode(plain))
        XCTAssertEqual(r.source, .plainText)
        XCTAssertEqual(r.headline, "panic(cpu 0 caller 0x1): \"Kernel data abort\"")
    }
}
