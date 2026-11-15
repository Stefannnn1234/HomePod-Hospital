import XCTest
@testable import HomePodRestoreCore

final class SysCfgTests: XCTestCase {

    /// Builds a real-format SysCfg blob (per Reviv): "SCfg" stored reversed as
    /// "gfCS", then each key stored REVERSED, value, and a NUL terminator.
    static func makeBlob(serial: String, wifi: [UInt8], bt: [UInt8], model: String? = nil) -> Data {
        var d = Data("gfCS".utf8)                       // reversed "SCfg" signature
        d.append(contentsOf: [0x01, 0x00, 0x00, 0x00])  // filler

        func entry(_ tag: String, _ value: [UInt8]) {
            d.append(Data(tag.reversed().map { UInt8($0.asciiValue!) }))  // reversed key
            d.append(contentsOf: value)
            d.append(0x00)                              // NUL terminator
        }
        entry("SrNm", Array(serial.utf8))
        entry("WMac", wifi)
        entry("BMac", bt)
        if let model { entry("Mod#", Array(model.utf8)) }
        return d
    }

    func testParsesIdentityFields() {
        let blob = Self.makeBlob(serial: "J5XBOGUS01",
                                 wifi: [0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33],
                                 bt:   [0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x34],
                                 model: "J42dAP")
        let parsed = SysCfgParser.parse(blob)
        XCTAssertTrue(parsed.looksValid)
        XCTAssertTrue(parsed.hasEssentials)
        XCTAssertEqual(parsed.serialNumber, "J5XBOGUS01")
        XCTAssertEqual(parsed.wifiMAC, "aa:bb:cc:11:22:33")
        XCTAssertEqual(parsed.bluetoothMAC, "aa:bb:cc:11:22:34")
        XCTAssertEqual(parsed.model, "J42dAP")
    }

    func testRawBytesPreservedVerbatim() {
        let blob = Self.makeBlob(serial: "ABC123", wifi: [1,2,3,4,5,6], bt: [6,5,4,3,2,1])
        let parsed = SysCfgParser.parse(blob)
        // The restore path depends on this: what we parsed carries the exact input.
        XCTAssertEqual(parsed.rawBytes, blob)
    }

    func testUnsignedGarbageIsNotValid() {
        let parsed = SysCfgParser.parse(Data([0x00, 0x11, 0x22, 0x33, 0x44]))
        XCTAssertFalse(parsed.looksValid)
        XCTAssertFalse(parsed.hasEssentials)
    }

    func testReadJobReturnsParsedDump() async {
        let blob = Self.makeBlob(serial: "READ0001", wifi: [0,1,2,3,4,5], bt: [5,4,3,2,1,0])
        let job = SysCfgJob(ecid: 0xABC, mode: .read, transport: FakeSysCfgTransport(seed: blob))
        let outcome = await job.run()
        guard case .read(let data) = outcome else { return XCTFail("expected .read, got \(outcome)") }
        XCTAssertEqual(data.serialNumber, "READ0001")
    }

    func testRestoreWritesVerbatimAndVerifies() async {
        let good = Self.makeBlob(serial: "GOOD0001", wifi: [0xDE,0xAD,0xBE,0xEF,0x00,0x01], bt: [0xDE,0xAD,0xBE,0xEF,0x00,0x02])
        // New chip starts blank; restore should write the recovered blob and verify.
        let transport = FakeSysCfgTransport(seed: Data())
        let job = SysCfgJob(ecid: 0xABC, mode: .restore(blob: good, confirmed: true), transport: transport)
        let outcome = await job.run()
        XCTAssertEqual(outcome, .restored)
        let written = await transport.lastWritten
        XCTAssertEqual(written, good)
    }

    func testRestoreRefusedWithoutConfirmation() async {
        let good = Self.makeBlob(serial: "GOOD0002", wifi: [1,1,1,1,1,1], bt: [2,2,2,2,2,2])
        let transport = FakeSysCfgTransport(seed: Data())
        let job = SysCfgJob(ecid: 0xABC, mode: .restore(blob: good, confirmed: false), transport: transport)
        let outcome = await job.run()
        guard case .failed = outcome else { return XCTFail("expected refusal") }
        let w1 = await transport.lastWritten
        XCTAssertNil(w1)
    }

    func testRestoreRefusedOnInvalidBlob() async {
        let junk = Data([0,1,2,3,4,5,6,7])
        let transport = FakeSysCfgTransport(seed: Data())
        let job = SysCfgJob(ecid: 0xABC, mode: .restore(blob: junk, confirmed: true), transport: transport)
        let outcome = await job.run()
        guard case .failed = outcome else { return XCTFail("expected refusal on invalid blob") }
        let w2 = await transport.lastWritten
        XCTAssertNil(w2)
    }
    func testSSHMarkerExtractionRoundTrip() {
        let blob = SysCfgTests.makeBlob(serial: "WIRE0001", wifi: [9,8,7,6,5,4], bt: [4,5,6,7,8,9])
        let b64 = blob.base64EncodedString()
        // Simulate noisy SSH output: banner + stderr + the marked payload.
        let out = """
        Warning: Permanently added '[127.0.0.1]:2222' (RSA) to known hosts.
        \(SSHRamdiskTransport.beginMarker)
        \(b64)
        \(SSHRamdiskTransport.endMarker)
        some trailing stderr noise
        """
        guard let inner = SSHRamdiskTransport.extractBetweenMarkers(out) else {
            return XCTFail("markers not found")
        }
        let decoded = Data(base64Encoded: inner.replacingOccurrences(of: "\n", with: ""))
        XCTAssertEqual(decoded, blob)
    }

    func testSSHMarkerExtractionMissing() {
        XCTAssertNil(SSHRamdiskTransport.extractBetweenMarkers("no markers here"))
    }
    func testIORegPropertyExtractionAndCarve() {
        // Real path: ioreg output (ANSI-colourized) carrying AppleDiagnosticDataSysCfg.
        let blob = SysCfgTests.makeBlob(serial: "CC4VKKTQHQK8",
                                        wifi: [0xd0,0x81,0x7a,0xe3,0x76,0x94],
                                        bt:   [0xd0,0x81,0x7a,0xe3,0x76,0x95])
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        let text = "    | | \u{1B}[0;0m\"AppleDiagnosticDataSysCfg\" = \u{1B}[0;31m<\(hex)>\u{1B}[0;0m\n    | | \"Other\" = <00>\n"
        guard let extracted = SSHRamdiskTransport.extractIORegHexProperty("AppleDiagnosticDataSysCfg", from: text) else {
            return XCTFail("ioreg property extraction failed")
        }
        XCTAssertEqual(extracted, blob)
        let parsed = SysCfgParser.parse(extracted)
        XCTAssertEqual(parsed.serialNumber, "CC4VKKTQHQK8")
        XCTAssertEqual(parsed.wifiMAC, "d0:81:7a:e3:76:94")
        XCTAssertEqual(parsed.bluetoothMAC, "d0:81:7a:e3:76:95")
    }
    func testWriteGateRefusesPlaceholderSink() async {
        // Default/placeholder sink must never write to NAND.
        let t1 = SSHRamdiskTransport(config: .init(sshTool: URL(fileURLWithPath: "/usr/bin/ssh")))
        XCTAssertFalse(t1.hasValidatedSink, "default placeholder sink must be treated as unvalidated")
        do { try await t1.writeRawBlob(Data([0,1,2,3])); XCTFail("write should have been refused") }
        catch { /* expected */ }

        // An explicit sink is considered validated (will actually attempt SSH).
        let t2 = SSHRamdiskTransport(config: .init(sshTool: URL(fileURLWithPath: "/usr/bin/ssh"),
                                                   sinkCommand: "some_real_syscfg_writer"))
        XCTAssertTrue(t2.hasValidatedSink)
    }

    func testIORegExtractionPrefersDataProperty() {
        // A property with no <hex> value returns nil, not garbage.
        XCTAssertNil(SSHRamdiskTransport.extractIORegHexProperty("Missing", from: "\"Other\" = 123"))
    }
}
