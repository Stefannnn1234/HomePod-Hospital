import XCTest
@testable import HomePodRestoreCore

final class PMUBootStateTests: XCTestCase {
    func testDecodesFields() throws {
        var b = [UInt8](repeating: 0, count: 21)
        b[0x01] = 0x24; b[0x02] = 3; b[0x03] = 0x11; b[0x0F] = 0x05; b[0x14] = 0xA0
        let s = try XCTUnwrap(PMUBootState(bytes: b))
        XCTAssertEqual(s.stage, 0x24)
        XCTAssertEqual(s.errorCount, 3)
        XCTAssertEqual(s.errorStage, 0x11)
        XCTAssertTrue(s.dfuRequested)
        XCTAssertTrue(s.summary.contains("boot errors: 3 — last one at stage 0x11"))
        XCTAssertNil(PMUBootState(bytes: [1, 2, 3]))
    }

    func testParsesHexDumpAndListOutput() throws {
        let dump = """
        :-) pmurw -r 0x4000 21
        0x4000: 00 24 00 00 00 00 00 00 00 00 00 00 00 01 00 05
        0x4010: 00 00 00 00 00
        [00000000:0000000] :-)
        """
        let a = try XCTUnwrap(PMUBootState.parse(pmurwOutput: dump))
        XCTAssertEqual(a.stage, 0x24)
        XCTAssertEqual(a.bootFlags0, 0x01)
        XCTAssertEqual(a.state, 0x05)
        XCTAssertFalse(a.dfuRequested)

        let list = (0..<21).map { String(format: "0x%02x", $0 == 2 ? 1 : 0) }.joined(separator: ",")
        XCTAssertEqual(PMUBootState.parse(pmurwOutput: list)?.errorCount, 1)
        XCTAssertNil(PMUBootState.parse(pmurwOutput: "Invalid command"))
    }
}
