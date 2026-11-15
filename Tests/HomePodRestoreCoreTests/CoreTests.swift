import XCTest
@testable import HomePodRestoreCore

final class DeviceInfoTests: XCTestCase {
    func testDFUSerialParsing() {
        let s = IBootSerial("CPID:7000 CPRV:11 CPFM:03 SCEP:01 BDID:38 ECID:001A2B3C4D5E6F70 IBFL:1C SRTG:[iBoot-1704.10] PWND:[checkm8]")
        XCTAssertEqual(s.cpid, 0x7000)
        XCTAssertEqual(s.bdid, 0x38)
        XCTAssertEqual(s.ecid, 0x001A2B3C4D5E6F70)
        XCTAssertEqual(s.srtg, "iBoot-1704.10")
        XCTAssertTrue(s.isPwned)
        XCTAssertTrue(s.isA8)
        XCTAssertTrue(s.isHomePodBoard)
        XCTAssertEqual(s.ecidString, "0x001A2B3C4D5E6F70")
    }

    func testRecoverySerialWithSpacesInBrackets() {
        let s = IBootSerial("CPID:7000 CPRV:11 CPFM:03 SCEP:01 BDID:38 ECID:0000000000000ABC IBFL:1D SRNM:[ABC DEF] IMEI:[]")
        XCTAssertEqual(s.srnm, "ABC DEF")
        XCTAssertEqual(s.ecid, 0xABC)
        XCTAssertFalse(s.isPwned)
    }

    func testModes() {
        XCTAssertEqual(DeviceMode(productID: 0x1227), .dfu)
        XCTAssertEqual(DeviceMode(productID: 0x1281), .recovery)
        XCTAssertEqual(DeviceMode(productID: 0x12A8), .restore)
    }

    func testPortLabel() {
        let d = ConnectedDevice(locationID: 0x0213_0000, productID: 0x1227, productName: "Apple Mobile Device (DFU Mode)", serial: "", speed: 2)
        XCTAssertEqual(d.portLabel, "USB 2-1.3")
        XCTAssertEqual(d.speedDescription, "High speed (480 Mbps)")
    }
}

final class LogParserTests: XCTestCase {
    /// A condensed real-world-shaped restore transcript (gaster + idevicerestore -d -e).
    static let transcript = """
    usb_timeout: 5
    [IOKit] Waiting for the USB handle with VID: 0x5AC, PID: 0x1227
    Found the USB handle.
    Stage: RESET
    Stage: SETUP
    Stage: SPRAY
    Stage: PATCH
    Now you can boot untrusted images.
    idevicerestore 1.0.0-215-gd2e1c4f
    Found device in DFU mode
    Identified device as b238aap, AudioAccessory1,1
    Extracting BuildManifest from IPSW
    Product Version: 18.3
    Product Build: 22K557 Major: 22
    Device supports Image4: true
    Variant: Customer Erase Install (IPSW)
    This restore will erase all device data.
    Using cached filesystem from '/Users/x/Library/Application Support/HomePod Restore/RestoreCache/18.3/myrootfs.dmg'
    Getting ApNonce in dfu mode... 01 02 03
    Trying to fetch new SHSH blob
    Sending iBSS (199353 bytes)...
    Sending iBEC (787049 bytes)...
    Recovery Mode Environment:
    Sending RestoreRamDisk (96469043 bytes)...
    Sending KernelCache (20057792 bytes)...
    Waiting for device to enter restore mode...
    Device is now in restore mode
    About to restore device...
    Connected to com.apple.mobile.restored, version 15
    Hardware Information:
    BoardID: 56
    ChipID: 28672
    UniqueChipID: 7364850127389056
    ProductionMode: true
    Waiting for NAND (28)
    ReverseProxy[Ctrl]: (status=1) Ready
    ampctl failure
    Creating partition map (11)
    Restoring image (13)
    \r[==========                                        ]  20.0%
    \r[==================================================] 100.0%
    Verifying restore (14)
    \r[=========================                         ]  50.0%
    Checking filesystems (15)
    Flashing firmware (18)
    Got status message
    Status: Restore Finished
    DONE
    """

    func testHappyPath() {
        var p = RestoreLogParser()
        var phases: [RestorePhase] = []
        for line in Self.transcript.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            p.consume(line)
            if phases.last != p.phase { phases.append(p.phase) }
        }
        XCTAssertEqual(phases, [.waiting, .unlocking, .preparing, .booting, .checkingHardware, .installing, .verifying, .finishing, .done])
        XCTAssertTrue(p.restoreFinished)
        XCTAssertTrue(p.enteredRestoreMode)
        XCTAssertEqual(p.hardware.boardID, 56)
        XCTAssertEqual(p.hardware.chipID, 28672)
        XCTAssertEqual(p.hardware.productionMode, true)
        XCTAssertNotNil(p.hardware.nandWaitSeconds)
        XCTAssertNil(p.primaryIssue, "noise must not count as an error")
        XCTAssertEqual(p.overallProgress, 1)
        XCTAssertTrue(p.issues.allSatisfy { $0.severity == .normal })
    }

    func testProgressWithinPhase() {
        var p = RestoreLogParser()
        p.consume("Restoring image (13)")
        p.consume("[=========================                         ]  50.0%")
        XCTAssertEqual(p.phase, .installing)
        XCTAssertEqual(p.phaseProgress, 0.5)
        XCTAssertGreaterThan(p.overallProgress, 0.3)
        XCTAssertLessThan(p.overallProgress, 0.7)
    }

    func testDiagnoses() {
        func diagnose(_ lines: [String]) -> String? {
            var p = RestoreLogParser()
            lines.forEach { p.consume($0) }
            return p.primaryIssue?.id
        }
        XCTAssertEqual(diagnose(["ERROR: This device isn't eligible for the requested build."]), "fw.notEligible")
        XCTAssertEqual(diagnose(["ERROR: Unable to get SHSH blobs for this device"]), "fw.notEligible")
        XCTAssertEqual(diagnose(["Waiting on NAND..."]), "hw.nand")
        XCTAssertEqual(diagnose(["Timeout waiting for NVRAM Service"]), "hw.nand")
        XCTAssertEqual(diagnose(["Status: Disk Failure"]), "hw.nand")
        XCTAssertEqual(diagnose(["ERROR: Device did not reconnect in recovery mode. Possibly invalid iBEC. Reset device and try again."]), "hw.soc")
        XCTAssertEqual(diagnose(["ERROR: Device failed to enter restore mode.", "Please make sure that usbmuxd is running."]), "hw.soc")
        XCTAssertEqual(diagnose(["failure when attempting to flash the nitrogen firmware"]), "transient.nitrogen")
        XCTAssertNil(diagnose(["Waiting for NAND (28)"]), "the normal NAND step is not a failure")
        XCTAssertNil(diagnose(["ReverseProxy[Conn]: (status=1) Ready", "No data to read (timeout)"]))
    }

    func testOperationParsing() {
        XCTAssertEqual(RestoreLogParser.parseOperation("Restoring image (13)")?.1, 13)
        XCTAssertNil(RestoreLogParser.parseOperation("Sending iBSS (199353 bytes)..."))
        XCTAssertNil(RestoreLogParser.parseOperation("ReverseProxy[Ctrl]: (status=1)"))
    }

    func testSupportReportRedactsECID() {
        let r = SupportReport.redact("CPID:7000 ECID:001A2B3C4D5E6F70 IBFL:1C")
        XCTAssertFalse(r.contains("4D5E6F70"))
        XCTAssertTrue(r.contains("ECID:001A2B…"))
    }
}

final class CatalogTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testBuildableReleases() throws {
        let otas = try FirmwareCatalog.decode(fixture("ota"))
        let donors = try FirmwareCatalog.decode(fixture("atv"))
        let releases = FirmwareCatalog.buildableReleases(otas: otas, donors: donors)
        XCTAssertFalse(releases.isEmpty)
        // No betas, one entry per build, newest first.
        XCTAssertEqual(Set(releases.map(\.build)).count, releases.count)
        XCTAssertFalse(releases.contains { $0.ota.isBeta })
        let r183 = try XCTUnwrap(releases.first { $0.build == "22K557" })
        XCTAssertEqual(r183.version, "18.3")
        XCTAssertTrue(r183.isSigned)
        XCTAssertTrue(r183.ota.isFullOTA)
        XCTAssertEqual(r183.donor?.buildid, "22K557")
        XCTAssertGreaterThan(r183.ota.filesize ?? 0, 2_000_000_000, "should pick the large full OTA")
        XCTAssertEqual(FirmwareCatalog.isSigned(build: "22K557", in: otas), true)
        XCTAssertEqual(FirmwareCatalog.compareVersions(releases[0].version, releases[1].version), .orderedDescending)
    }

    func testFallbackManifest() {
        XCTAssertEqual(PrebuiltManifest.fallback.recommended?.build, "22K557")
    }

    func testManifestDecodes() throws {
        let json = """
        {"schema":1,"announcement":"hi","firmwares":[{"version":"18.3","build":"22K557","url":"https://nicsfix.com/ipsw/18.3.ipsw","size":3431162133,"recommended":true}]}
        """
        let m = try JSONDecoder().decode(PrebuiltManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.recommended?.version, "18.3")
        XCTAssertNil(m.donateURL)
    }
}

final class BuildProgressTests: XCTestCase {
    func testCheckpoints() {
        var p = BuildLogProgress()
        p.consume("extracting ota to '/tmp/x/ota'")
        p.consume("Extracting chunk 000...")
        p.consume("Extracting chunk 001...")
        XCTAssertEqual(p.step, "Unpacking HomePod software (chunk 2)")
        p.consume("Compressing IPSW")
        XCTAssertEqual(p.fraction, 0.83)
        p.consume("Done!!")
        XCTAssertEqual(p.fraction, 1.0)
    }

    func testRunScriptQuotesPaths() {
        let s = IPSWBuilder.makeRunScript(script: URL(fileURLWithPath: "/w/makeipsw.sh"),
                                          ota: URL(fileURLWithPath: "/w/ota.zip"),
                                          donor: URL(fileURLWithPath: "/w/donor.ipsw"),
                                          output: URL(fileURLWithPath: "/w/out.ipsw"),
                                          keys: URL(fileURLWithPath: "/w/keys.zip"),
                                          log: URL(fileURLWithPath: "/L/Logs/HomePod Restore/b.log"),
                                          exitFile: URL(fileURLWithPath: "/w/exitcode"), uid: 501, gid: 20)
        XCTAssertTrue(s.contains("'/w/makeipsw.sh' '/w/ota.zip' '/w/donor.ipsw' '/w/out.ipsw' '/w/keys.zip'"))
        XCTAssertTrue(s.contains("> '/L/Logs/HomePod Restore/b.log' 2>&1"))
        XCTAssertTrue(s.contains("chown 501:20"))
    }
}

final class DistributionTests: XCTestCase {
    /// Guards against typos when editing the manifest you upload to nicsfix.com.
    func testShippedManifestDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Distribution/manifest.json")
        let m = try JSONDecoder().decode(PrebuiltManifest.self, from: Data(contentsOf: url))
        XCTAssertFalse(m.firmwares.isEmpty)
        XCTAssertNotNil(m.recommended)
        for f in m.firmwares {
            XCTAssertTrue(f.url.absoluteString.hasPrefix("https://"))
            if let sha = f.sha256 { XCTAssertEqual(sha.count, 64) }
        }
    }

    func testCreditsHaveLinks() {
        XCTAssertTrue(Credit.all.contains { $0.name == "tihmstar" })
        XCTAssertTrue(Credit.all.contains { $0.name == "David Ryskalczyk" })
        XCTAssertTrue(Credit.all.allSatisfy { !$0.links.isEmpty })
    }
}

final class RealDeviceTests: XCTestCase {
    /// Captured from a real 1st-gen HomePod in DFU mode (Nic's MacBook Pro, Nov 2026).
    func testRealHomePodDFU() {
        let d = ConnectedDevice(locationID: 0x0210_0000, productID: 0x1227, productName: "Apple Mobile Device (DFU Mode)",
                                serial: "CPID:7000 CPRV:11 CPFM:03 SCEP:01 BDID:38 ECID:001250C230D9A0A6 IBFL:1C SRTG:[iBoot-1992.0.0.1.19]",
                                speed: 2)
        XCTAssertEqual(d.mode, .dfu)
        let ib = d.iboot!
        XCTAssertTrue(ib.isA8)
        XCTAssertTrue(ib.isHomePodBoard)
        XCTAssertEqual(ib.ecid, 0x001250C230D9A0A6)
        XCTAssertEqual(ib.srtg, "iBoot-1992.0.0.1.19")
        XCTAssertFalse(ib.isPwned)
        XCTAssertEqual(d.portLabel, "USB 2-1")
        XCTAssertEqual(d.speedDescription, "High speed (480 Mbps)")
    }
}
