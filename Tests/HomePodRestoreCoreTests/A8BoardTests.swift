import XCTest
@testable import HomePodRestoreCore

final class A8BoardTests: XCTestCase {
    private func dfu(_ bdid: String, cpid: String = "7000") -> IBootSerial {
        IBootSerial("CPID:\(cpid) CPRV:11 CPFM:03 SCEP:01 BDID:\(bdid) ECID:001A2B3C4D5E6F70 IBFL:1C SRTG:[iBoot-1704.10]")
    }

    func testRetailHomePod() {
        let ib = dfu("38")
        XCTAssertEqual(ib.a8Board?.kind, .homePod)
        XCTAssertEqual(ib.a8Board?.isRetailHomePod, true)
        XCTAssertTrue(ib.isHomePodBoard)
        XCTAssertNil(A8BoardGate.restoreBlocker(ib))
        XCTAssertNil(A8BoardGate.bootBlocker(ib))
        XCTAssertNil(A8BoardGate.boardNote(ib))
    }

    func testDevFusedHomePodCanBootButNotRestore() {
        let ib = dfu("39")
        XCTAssertEqual(ib.a8Board?.kind, .homePod)
        XCTAssertEqual(ib.a8Board?.isDevFused, true)
        XCTAssertTrue(ib.isHomePodBoard)
        XCTAssertNotNil(A8BoardGate.restoreBlocker(ib))
        XCTAssertNil(A8BoardGate.bootBlocker(ib))
        XCTAssertNotNil(A8BoardGate.boardNote(ib))
    }

    func testPrototypeBoard() {
        for id in ["1A", "1B"] {
            let ib = dfu(id)
            XCTAssertEqual(ib.a8Board?.kind, .homePodPrototype, id)
            XCTAssertEqual(ib.a8Board?.productType, "AudioAccessory1,2")
            XCTAssertFalse(ib.isHomePodBoard)
            XCTAssertNotNil(A8BoardGate.restoreBlocker(ib))
            XCTAssertNil(A8BoardGate.bootBlocker(ib))
        }
    }

    func testOtherA8ProductsAreBlocked() {
        let expected: [(String, String)] = [("04", "iPhone 6 Plus"), ("07", "iPhone 6"), ("08", "iPad mini 4 (Wi-Fi)"),
                                            ("0B", "iPad mini 4 (Cellular)"), ("10", "iPod touch (6th generation)"),
                                            ("34", "Apple TV HD"), ("35", "Apple TV HD")]
        for (id, name) in expected {
            let ib = dfu(id)
            XCTAssertEqual(ib.a8Board?.kind, .otherProduct, id)
            XCTAssertEqual(ib.a8Board?.productName, name, id)
            XCTAssertTrue(A8BoardGate.bootBlocker(ib)?.contains(name) == true, id)
            XCTAssertNotNil(A8BoardGate.restoreBlocker(ib), id)
            XCTAssertNil(A8BoardGate.boardNote(ib), id)
        }
    }

    func testUnknownBoardAndNonA8() {
        XCTAssertNil(dfu("42").a8Board)
        XCTAssertNotNil(A8BoardGate.bootBlocker(dfu("42")))
        XCTAssertEqual(A8BoardGate.bootBlocker(dfu("38", cpid: "8000")), A8BoardGate.notA8)
        XCTAssertNil(dfu("38", cpid: "8000").a8Board)
        // No board id in the string at all: don't block on a guess.
        let noBoard = IBootSerial("CPID:7000 CPRV:11 ECID:001A2B3C4D5E6F70")
        XCTAssertNil(A8BoardGate.restoreBlocker(noBoard))
        XCTAssertNil(A8BoardGate.bootBlocker(noBoard))
    }
}
