import XCTest
@testable import HomePodRestoreCore

/// Runs RestoreJob end-to-end against fake gaster/idevicerestore scripts.
/// Opt-in because it writes into the user tools folder:
///   HOMEPOD_FAKE_TOOLS=1 swift test --filter JobTests
final class JobTests: XCTestCase {
    var bin: URL { ToolLocator.userToolsDirectory }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOMEPOD_FAKE_TOOLS"] == "1")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for t in ["gaster", "idevicerestore"] { try? FileManager.default.removeItem(at: bin.appendingPathComponent(t)) }
    }

    func install(_ name: String, _ body: String) throws {
        let u = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }

    func fakeFirmware() -> FirmwareItem {
        FirmwareItem(path: "/tmp/fake 18.3.ipsw",
                     info: IPSWInfo(productVersion: "18.3", buildVersion: "22K557", supportedProductTypes: ["AudioAccessory1,1"],
                                    osPath: "myrootfs.dmg", osCompressed: false, osUncompressedSize: nil, isCustomHomePodBuild: true),
                     origin: .prebuilt, addedAt: Date())
    }

    final class Collector: @unchecked Sendable {
        let lock = NSLock(); var snaps: [RestoreJob.Snapshot] = []
        func add(_ s: RestoreJob.Snapshot) { lock.lock(); snaps.append(s); lock.unlock() }
        var phases: [RestorePhase] { lock.lock(); defer { lock.unlock() }; var out: [RestorePhase] = []; for s in snaps where out.last != s.phase { out.append(s.phase) }; return out }
    }

    func testSuccessfulRestoreWithFlakyUnlock() async throws {
        // gaster fails the first pwn, then succeeds; it must receive GASTER_ECID.
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("gaster-attempts-\(UUID().uuidString)")
        try install("gaster", """
        echo "usb_timeout: 5"
        [ "$GASTER_ECID" = "0x001A2B3C4D5E6F70" ] || { echo "bad ecid env: $GASTER_ECID"; exit 9; }
        if [ "$1" = "pwn" ]; then
          n=$(cat '\(state.path)' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(state.path)'
          echo "[IOKit] Waiting for the USB handle with VID: 0x5AC, PID: 0x1227"
          [ $n -lt 2 ] && { echo "checkm8 failed"; exit 1; }
          echo "Stage: RESET"; echo "Now you can boot untrusted images."
        fi
        exit 0
        """)
        let transcript = LogParserTests.transcript.replacingOccurrences(of: "'", with: "")
        try install("idevicerestore", """
        for a in "$@"; do echo "arg: $a"; done
        cat <<'LOG'
        \(transcript)
        LOG
        exit 0
        """)
        let c = Collector()
        let job = RestoreJob(kind: .restore, ecid: 0x001A2B3C4D5E6F70, locationID: 0x01100000, firmware: fakeFirmware(),
                             gasterTargetsECID: true) { c.add($0) }
        await job.run()
        let last = job.currentSnapshot
        XCTAssertEqual(last.outcome, .succeeded, last.status)
        XCTAssertEqual(last.unlockAttempts, 2)
        XCTAssertEqual(last.phase, .done)
        XCTAssertEqual(last.hardware.boardID, 56)
        XCTAssertTrue(last.recentLines.contains("arg: -i"))
        XCTAssertTrue(last.recentLines.contains("arg: 0x001A2B3C4D5E6F70"))
        XCTAssertTrue(last.recentLines.contains("arg: /tmp/fake 18.3.ipsw"), "path with a space must stay one argument")
        XCTAssertFalse(last.recentLines.contains("arg: -z"))
        XCTAssertTrue(c.phases.contains(.installing))
        let log = try String(contentsOf: job.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("Status: Restore Finished"))
        try? FileManager.default.removeItem(at: job.logURL)
    }

    func testNANDFailureIsDiagnosed() async throws {
        try install("gaster", #"echo "Now you can boot untrusted images."; exit 0"#)
        try install("idevicerestore", """
        echo "Device is now in restore mode"
        echo "Waiting for NAND (28)"
        echo "Timeout waiting for NVRAM Service"
        echo "ERROR: Unable to restore device"
        exit 255
        """)
        let job = RestoreJob(kind: .restore, ecid: 0xABC, locationID: 1, firmware: fakeFirmware(), gasterTargetsECID: true) { _ in }
        await job.run()
        let s = job.currentSnapshot
        guard case .failed(let id, _) = s.outcome else { return XCTFail("expected failure, got \(s.outcome)") }
        XCTAssertEqual(id, "hw.nand", "lines: \(s.recentLines) status: \(s.status)")
        XCTAssertEqual(s.primaryIssue?.category, .hardwareNAND)
        try? FileManager.default.removeItem(at: job.logURL)
    }

    func testPwnFailureAfterThreeAttempts() async throws {
        try install("gaster", #"echo "[IOKit] Waiting for the USB handle"; exit 1"#)
        let job = RestoreJob(kind: .quickCheck, ecid: 0xABC, locationID: 1, firmware: nil, gasterTargetsECID: false) { _ in }
        await job.run()
        let s = job.currentSnapshot
        XCTAssertEqual(s.unlockAttempts, 3)
        guard case .failed(let id, _) = s.outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(id, "conn.pwn")
        try? FileManager.default.removeItem(at: job.logURL)
    }

    func testBootTestPassesZAndSucceedsInRestoreMode() async throws {
        try install("gaster", #"echo "Now you can boot untrusted images."; exit 0"#)
        try install("idevicerestore", """
        for a in "$@"; do echo "arg: $a"; done
        echo "Sending iBSS (199353 bytes)..."
        echo "Device is now in restore mode. Exiting as requested."
        exit 0
        """)
        let job = RestoreJob(kind: .bootTest, ecid: 0xABC, locationID: 1, firmware: fakeFirmware(), gasterTargetsECID: true) { _ in }
        await job.run()
        let s = job.currentSnapshot
        XCTAssertEqual(s.outcome, .succeeded, s.status)
        XCTAssertTrue(s.recentLines.contains("arg: -z"))
        try? FileManager.default.removeItem(at: job.logURL)
    }

    func testCancel() async throws {
        // Note: on Linux, children spawned from Swift-concurrency threads inherit a
        // blocked signal mask, so only the final SIGKILL lands — this still passes.
        try install("gaster", #"echo "Now you can boot untrusted images."; exit 0"#)
        try install("idevicerestore", "trap 'echo got-int; exit 130' INT\necho \"Restoring image (13)\"\nwhile true; do sleep 0.2; done")
        let job = RestoreJob(kind: .restore, ecid: 0xABC, locationID: 1, firmware: fakeFirmware(), gasterTargetsECID: true) { _ in }
        let t = Task { await job.run() }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        job.cancel()
        await t.value
        XCTAssertEqual(job.currentSnapshot.outcome, .cancelled)
        try? FileManager.default.removeItem(at: job.logURL)
    }
}

