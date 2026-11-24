import XCTest
@testable import HomePodRestoreCore

final class NANDInfoTests: XCTestCase {
    /// `ideviceinfo -q com.apple.disk_usage -k NANDInfo` from a healthy B238a
    /// running audioOS (base64, one line). No serials or ECIDs in it.
    private func fixtureText() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "nandinfo-b238a", withExtension: "b64", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesRealPod() throws {
        let s = try ASPStats.parse(ideviceinfoOutput: fixtureText())
        XCTAssertEqual(s.records.count, 356)
        XCTAssertEqual(s.value(.numFactoryBad), 13)
        XCTAssertEqual(s.value(.numGrownBad), 0)
        XCTAssertEqual(s.value(.numPfail), 0)
        XCTAssertEqual(s.value(.numEfail), 0)
        XCTAssertEqual(s.value(.boots), 361)
        XCTAssertEqual(s.value(.uncleanBoots), 118)
        XCTAssertEqual(s.value(.powerOnHours), 1023)
        XCTAssertEqual(s.value(.bandErases), 563_507)
        XCTAssertEqual(s.value(.numVirtualBlocks), 1056)
        XCTAssertEqual(s.value(.hottestCycle), 547)
        XCTAssertEqual(s.value(.coldestCycle), 516)
        XCTAssertEqual(s.value(.numSyscfgWrites), 32)
        XCTAssertEqual(s.values(.ecBins)?.count, 100)
        XCTAssertNil(s.value(.ueccReads), "this pod's controller doesn't export key 414")
        // Records after the zero-padding gap (key 0x146 → 0x147) are kept.
        XCTAssertEqual(s.records[0x147]?.count, 22)
        XCTAssertEqual(s.bytesPerVirtualBlock, 16_777_216)
        XCTAssertEqual(s.rawCapacityBytes, 17_716_740_096)
        XCTAssertEqual(try XCTUnwrap(s.averageEraseCycles), 533.6, accuracy: 0.1)
    }

    func testHealthyReport() throws {
        let r = NANDHealthReport(stats: try ASPStats.parse(ideviceinfoOutput: fixtureText()))
        XCTAssertEqual(r.verdict, .good)
        XCTAssertTrue(r.problems.isEmpty)
        let rows = Dictionary(uniqueKeysWithValues: r.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Bad blocks"], "13 from the factory, 0 since")
        XCTAssertEqual(rows["Wear"], "~534 erase cycles per block (busiest 547, quietest 516)")
        XCTAssertEqual(rows["Written to flash"], "9.0 TB (5.8 TB asked for by the system)")
        XCTAssertEqual(rows["Raw flash"], "17.7 GB (1056 blocks of 16 MB)")
        XCTAssertEqual(rows["Boots"], "361 (118 after power was cut)")
    }

    func testPlistOutputAndErrors() throws {
        let blob = Self.blob([(1, [1]), (47, [3]), (36, [0]), (22, [2])])
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <data>\(blob.base64EncodedString())</data>
        </plist>
        """
        let s = try ASPStats.parse(ideviceinfoOutput: plist)
        XCTAssertEqual(s.value(.numGrownBad), 3)
        XCTAssertThrowsError(try ASPStats.parse(ideviceinfoOutput: "ERROR: Could not connect to lockdownd: Pairing dialog response pending (-19)"))
        XCTAssertThrowsError(try ASPStats.parse(ideviceinfoOutput: "No device found."))
        XCTAssertThrowsError(try ASPStats.parse(Data(count: 64)))
    }

    func testWarningAndFailingVerdicts() throws {
        let worn = NANDHealthReport(stats: try ASPStats.parse(Self.blob([(46, [10]), (47, [3]), (22, [2])])))
        XCTAssertEqual(worn.verdict, .warning)
        XCTAssertEqual(worn.problems, ["Grown bad blocks: 3", "Program failures: 2"])
        XCTAssertFalse(worn.rows.contains { $0.label == "Grown bad blocks" }, "shown in the Bad blocks row instead")

        let dead = NANDHealthReport(stats: try ASPStats.parse(Self.blob([(47, [40]), (414, [7])])))
        XCTAssertEqual(dead.verdict, .failing)
        XCTAssertTrue(dead.headline.contains("uncorrectable reads"))
    }

    /// Build a blob in the NANDInfo layout, with a padding gap and a zero tail.
    static func blob(_ records: [(UInt32, [UInt64])]) -> Data {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for (i, (key, values)) in records.enumerated() {
            put32(key); put32(UInt32(values.count)); values.forEach(put64)
            if i == 0 { d.append(Data(count: 24)) }
        }
        d.append(Data(count: 128))
        return d
    }
}
