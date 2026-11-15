import XCTest
@testable import HomePodRestoreCore

/// Rules for pod-side ioreg use, the DIAGS write path, and script push order.
final class DiagsPathTests: XCTestCase {

    private struct ScriptedShell: RamdiskShell {
        let reply: String
        func run(_ command: String) async throws -> String { reply }
        func dumpBinary(_ command: String) async throws -> Data { Data() }
    }

    // MARK: ioreg rules

    func testQueriesAreTargeted() {
        XCTAssertEqual(RamdiskIOReg.query(forClass: "ASPStorage"), "hpior -r -c ASPStorage -l")
        XCTAssertEqual(RamdiskIOReg.query(forClass: "IOPMrootDomain", properties: true, nodeOnly: true),
                       "hpior -r -d 1 -c IOPMrootDomain -l")
        XCTAssertEqual(RamdiskIOReg.query(forClass: "IOPlatformExpertDevice", properties: false),
                       "hpior -r -c IOPlatformExpertDevice")
        XCTAssertNil(RamdiskIOReg.query(forClass: "ASPStorage; reboot"))
        XCTAssertNil(RamdiskIOReg.query(forClass: ""))
    }

    func testPreludeStripsAnsiAndSetsPath() {
        XCTAssertTrue(RamdiskIOReg.prelude.hasPrefix("PATH=/usr/bin:"))
        XCTAssertTrue(RamdiskIOReg.prelude.contains("printf '\\033'"))
        XCTAssertTrue(RamdiskIOReg.prelude.contains("[0-9;]*m//g"))
        XCTAssertTrue(RamdiskIOReg.prelude.contains("ioreg -w 0"))
    }

    /// A bare `ioreg -l` kernel-panics the ramdisk; every query must be `-r -c`.
    func testNoPodCommandDumpsTheWholeRegistry() {
        let commands = [
            SSHRamdiskTransport.Config.defaultDumpCommand,
            SSHRamdiskTransport.writeProbeCommand,
            DiagnosticsController.panicDeviceProbeCommand,
            DiagsKextSink().probeCommand(),
        ]
        for command in commands {
            XCTAssertFalse(command.contains("ioreg -l"), command)
            XCTAssertFalse(command.contains("hpior -l"), command)
            for piece in command.components(separatedBy: "hpior ").dropFirst() {
                XCTAssertTrue(piece.hasPrefix("-r "), "untargeted query: hpior \(piece.prefix(40))")
            }
        }
        for cls in DiagnosticsController.snapshotClasses {
            XCTAssertNotNil(RamdiskIOReg.query(forClass: cls))
        }
    }

    func testDumpCommandFallsBackToTheWritableKext() {
        let command = SSHRamdiskTransport.Config.defaultDumpCommand
        XCTAssertTrue(command.contains("-c AppleDiagnosticDataAccessReadOnly -l"))
        XCTAssertTrue(command.contains("-c AppleDiagnosticDataAccess -l"))
    }

    // MARK: Boot-args

    func testRamdiskBootArgsAreNotDestructive() {
        XCTAssertFalse(GasterRamdiskBooter.Config.sshRamdiskBootArgs.contains("nand-enable-reformat"))
        XCTAssertFalse(GasterRamdiskBooter.Config.sshRamdiskBootArgs.contains("-restore"))
        XCTAssertTrue(GasterRamdiskBooter.Config.destructiveRestoreBootArgs.contains("nand-enable-reformat=1"))
        XCTAssertEqual(RamdiskFirmware.pinnedVersion, "18.3")
    }

    // MARK: DIAGS layout + sink

    func testDiagsLayoutUsesItsOwnImageSet() {
        let layout = SSHRDLayout(root: URL(fileURLWithPath: "/tmp/SSHRD_Script"))
        XCTAssertFalse(layout.isDiags)
        XCTAssertEqual(layout.ramdiskDir.lastPathComponent, "sshramdisk")
        XCTAssertTrue(layout.diags.isDiags)
        XCTAssertEqual(layout.diags.ramdiskDir.lastPathComponent, "diagsramdisk")
        XCTAssertEqual(layout.diagsScript.lastPathComponent, "diags_boot.sh")
    }

    func testDiagsSinkDefaults() {
        let sink = DiagsKextSink()
        XCTAssertEqual(sink.type, .diagsKext)
        XCTAssertEqual(sink.settings.toolPath, "/diags/syscfg_write")
        XCTAssertFalse(sink.isValidated)
        XCTAssertTrue(sink.probeCommand().contains("/diags/syscfg_write"))
    }

    func testDiagsSinkProbeTellsWritableFromReadOnly() async throws {
        let stock = """
            == AppleDiagnosticDataAccess ==
            == AppleDiagnosticDataAccessReadOnly ==
            +-o AppleDiagnosticDataAccessReadOnly  <class AppleDiagnosticDataAccessReadOnly, id 0x1000003e0, registered, matched, active>
            == writer ==
            HPDIAGS_TOOL=missing
            """
        let onStock = try await DiagsKextSink().probe(via: ScriptedShell(reply: stock))
        XCTAssertFalse(onStock.nodePresent)

        let diags = """
            == AppleDiagnosticDataAccess ==
            +-o AppleDiagnosticDataAccess  <class AppleDiagnosticDataAccess, id 0x100000321, registered, matched, active>
            == AppleDiagnosticDataAccessReadOnly ==
            == writer ==
            HPDIAGS_TOOL=present
            """
        let onDiags = try await DiagsKextSink().probe(via: ScriptedShell(reply: diags))
        XCTAssertTrue(onDiags.nodePresent)
        XCTAssertEqual(onDiags.sink, .diagsKext)
    }

    func testDiagsSinkRefusesToWriteWithoutAConfirmedCommand() async {
        var settings = DiagsKextSink.Settings()
        settings.validation = WriteSinkValidation(userClientOpened: true, lockerRead: true, roundTripVerified: true)
        let sink = DiagsKextSink(settings: settings)
        // Round-trip flags alone are not enough: the write command is unset.
        XCTAssertFalse(sink.isValidated)
        do {
            try await sink.commit(blob: Data([0x01]), via: ScriptedShell(reply: ""))
            XCTFail("commit should have been refused")
        } catch {
            // expected
        }
    }

    // MARK: Script push

    func testPushedScriptsWinOverBakedInOnes() {
        XCTAssertTrue(DiagCommands.path.hasPrefix(DiagCommands.pushDirectory + ":"))
        XCTAssertTrue(DiagCommands.path.contains("/usr/local/bin"))
    }
}
