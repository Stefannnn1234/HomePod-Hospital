import XCTest
@testable import HomePodRestoreCore

/// The Nicotine (Linux) boot must stay command-for-command what boot-linux.sh
/// does. These tests pin the sequence and run it against fake tools in a
/// temporary folder (nothing is written outside it, no hardware involved).
final class NicotineTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nicotine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: helpers

    /// An image folder with every boot file present (empty files are enough).
    func makeLayout(omitting omitted: [String] = []) throws -> NicotineLayout {
        let layout = NicotineLayout(root: tmp.appendingPathComponent("linux-homepod", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.img4Dir, withIntermediateDirectories: true)
        for f in layout.bootFiles {
            if omitted.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
            } else {
                try Data("x".utf8).write(to: f)
            }
        }
        return layout
    }

    func install(_ name: String, _ body: String) throws -> URL {
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let u = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// The commands a fake tool recorded, one "tool arg arg" per line, with the
    /// image folder's path shortened to "$D".
    func recorded(_ record: URL, layout: NicotineLayout) -> [String] {
        let text = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.replacingOccurrences(of: layout.img4Dir.path, with: "$D") }
    }

    /// boot-linux.sh, default mode, as "tool args" lines.
    static let scriptCommands = [
        "gaster pwn",
        "gaster reset",
        "irecovery -f $D/iBSS.dev-hoolock.img4",
        "irecovery -f $D/iBEC.dev-hoolock.img4",
        "irecovery -f $D/RestoreDeviceTree_b238aap.img4",
        "irecovery -c devicetree",
        "irecovery -f $D/RestoreTrustCache.img4",
        "irecovery -c firmware",
        "irecovery -f $D/RestoreKernelCache_m1n1-linux.img4",
        "irecovery -c bootx",
    ]

    // MARK: the sequence

    func testStepsAreBootLinuxShCommandForCommand() {
        let layout = NicotineLayout(root: URL(fileURLWithPath: "/N"))
        let steps = NicotineBooter.steps(for: layout)
        let commands = steps.map { ([$0.tool.rawValue] + $0.arguments).joined(separator: " ").replacingOccurrences(of: "/N/img4", with: "$D") }
        XCTAssertEqual(commands, Self.scriptCommands)

        // `|| exit 1` in the script: pwn, reset, iBSS, iBEC, device tree, payload.
        XCTAssertEqual(steps.map(\.stopsOnFailure), [true, true, true, true, true, false, false, false, true, false])
        // The script's sleeps: 1 s after reset, 3 s after iBSS, 4 s after iBEC.
        XCTAssertEqual(steps.map(\.pauseAfter), [0, 1, 3, 4, 0, 0, 0, 0, 0, 0])
    }

    func testBootFilesAreTheOnesTheScriptChecks() {
        let layout = NicotineLayout(root: URL(fileURLWithPath: "/N"))
        // The boot loaders (iBSS/iBEC) are built from Apple's release firmware
        // and are not payload files; the payload carries these three.
        XCTAssertEqual(layout.bootFiles.map(\.lastPathComponent), [
            "RestoreKernelCache_m1n1-linux.img4",
            "RestoreDeviceTree_b238aap.img4", "RestoreTrustCache.img4",
        ])
        XCTAssertEqual(layout.configScript.path, "/N/homepod-config.sh")
        XCTAssertEqual(layout.configDir.path, "/N/config")
    }

    func testMissingFilesAreNamed() throws {
        let layout = try makeLayout(omitting: ["RestoreTrustCache.img4", "RestoreDeviceTree_b238aap.img4"])
        XCTAssertFalse(layout.isComplete)
        XCTAssertEqual(layout.missingBootFiles, ["img4/RestoreDeviceTree_b238aap.img4", "img4/RestoreTrustCache.img4"])

        let full = try makeLayout()
        XCTAssertTrue(full.isComplete)
        XCTAssertEqual(full.missingBootFiles, [])
        XCTAssertNotNil(full.imageDescription)

        let nowhere = NicotineLayout(root: tmp.appendingPathComponent("nope"))
        XCTAssertFalse(nowhere.folderExists)
        XCTAssertFalse(nowhere.isComplete)
    }

    func testBootRunsTheScriptSequence() async throws {
        let layout = try makeLayout()
        let record = tmp.appendingPathComponent("record.txt")
        // The trust-cache upload fails, as on older iBoots: the script carries on.
        let gaster = try install("gaster", "echo \"gaster $*\" >> '\(record.path)'; echo \"usb ok\"; exit 0")
        let irecovery = try install("irecovery", """
        echo "irecovery $*" >> '\(record.path)'
        case "$*" in *RestoreTrustCache*) echo "upload refused"; exit 3 ;; esac
        exit 0
        """)
        let log = Lines()
        let booter = NicotineBooter(config: .init(layout: layout, gaster: gaster, irecovery: irecovery, pauseScale: 0))
        try await booter.boot(onLog: { log.add($0) })

        XCTAssertEqual(recorded(record, layout: layout), Self.scriptCommands)
        let lines = log.all
        XCTAssertTrue(lines.contains("[*] Put the HomePod in DFU, then: gaster pwn"))
        XCTAssertTrue(lines.contains("    $ gaster pwn"))
        XCTAssertTrue(lines.contains("    usb ok"))
        XCTAssertTrue(lines.contains("    (exit 3)"))
        XCTAssertEqual(lines.last, "[*] " + NicotineBooter.afterBootMessage)
    }

    func testBootStopsWhereTheScriptStops() async throws {
        let layout = try makeLayout()
        let record = tmp.appendingPathComponent("record.txt")
        let gaster = try install("gaster", "echo \"gaster $*\" >> '\(record.path)'; exit 0")
        let irecovery = try install("irecovery", """
        echo "irecovery $*" >> '\(record.path)'
        case "$*" in *iBEC*) exit 1 ;; esac
        exit 0
        """)
        let booter = NicotineBooter(config: .init(layout: layout, gaster: gaster, irecovery: irecovery, pauseScale: 0))
        do {
            try await booter.boot(onLog: { _ in })
            XCTFail("the boot should have stopped at iBEC")
        } catch let error as NicotineError {
            XCTAssertEqual(error, .stepFailed(command: "irecovery -f iBEC.dev-hoolock.img4", exitCode: 1))
            XCTAssertEqual(error.issue?.id, "nicotine.iboot")
        }
        XCTAssertEqual(recorded(record, layout: layout), Array(Self.scriptCommands.prefix(4)))
    }

    func testPwnFailureAndPreflight() async throws {
        let layout = try makeLayout()
        let gaster = try install("gaster", "exit 1")
        let irecovery = try install("irecovery", "exit 0")
        do {
            try await NicotineBooter(config: .init(layout: layout, gaster: gaster, irecovery: irecovery, pauseScale: 0)).boot(onLog: { _ in })
            XCTFail("gaster pwn failed, the boot must stop")
        } catch let error as NicotineError {
            XCTAssertEqual(error, .stepFailed(command: "gaster pwn", exitCode: 1))
            XCTAssertEqual(error.issue?.id, "nicotine.pwn")
        }

        // Nothing is run when a file or a tool is missing.
        let partial = try makeLayout(omitting: ["RestoreKernelCache_m1n1-linux.img4", "RestoreTrustCache.img4"])
        XCTAssertThrowsError(try NicotineBooter(config: .init(layout: partial, gaster: gaster, irecovery: irecovery)).preflight()) { e in
            XCTAssertEqual(e as? NicotineError,
                           .filesMissing(folder: partial.root.path, files: ["img4/RestoreKernelCache_m1n1-linux.img4", "img4/RestoreTrustCache.img4"]))
            XCTAssertEqual((e as? NicotineError)?.issue?.id, "nicotine.files")
        }
        let full = try makeLayout()
        let noTool = tmp.appendingPathComponent("bin/not-there")
        XCTAssertThrowsError(try NicotineBooter(config: .init(layout: full, gaster: noTool, irecovery: irecovery)).preflight()) { e in
            XCTAssertEqual(e as? NicotineError, .toolMissing("gaster"))
        }
        XCTAssertThrowsError(try NicotineBooter(config: .init(layout: NicotineLayout(root: tmp.appendingPathComponent("nope")),
                                                                gaster: gaster, irecovery: irecovery)).preflight()) { e in
            XCTAssertEqual(e as? NicotineError, .folderMissing(tmp.appendingPathComponent("nope").path))
        }
    }

    // MARK: the booted pod

    func testOSReleaseParsing() {
        let text = """
        NAME="Nicotine"
        PRETTY_NAME="Nicotine (Doof Different)"
        ID=nicotine
        VERSION_ID="105"
        VERSION="build 105"
        """
        let info = NicotinePodInfo.parse(osRelease: text)
        XCTAssertEqual(info.prettyName, "Nicotine (Doof Different)")
        XCTAssertEqual(info.version, "build 105")
        XCTAssertEqual(info.versionLine, "Nicotine (Doof Different) — build 105")
        XCTAssertEqual(NicotinePodInfo.parse(osRelease: "garbage\n\n").versionLine, "unknown version")
        XCTAssertEqual(NicotinePodInfo.parse(osRelease: "VERSION=7\r\n").versionLine, "7")
    }

    func testPodCommands() async throws {
        let pod = NicotinePod()
        XCTAssertEqual(NicotinePod.webUI.absoluteString, "http://172.16.42.1/")
        XCTAssertEqual(pod.reachabilityArguments, ["-s", "-o", "/dev/null", "-m", "3", "http://172.16.42.1/"])
        let ssh = pod.sshArguments("cat /etc/os-release")
        XCTAssertEqual(ssh.suffix(2), ["root@172.16.42.1", "cat /etc/os-release"])
        XCTAssertTrue(ssh.contains("BatchMode=yes"))
        XCTAssertTrue(ssh.contains("UserKnownHostsFile=/dev/null"))

        // Reachability and version through fake curl / ssh.
        let curlOK = try install("curl", "exit 0")
        let sshOK = try install("ssh", "echo 'PRETTY_NAME=\"Nicotine (Doof Different)\"'; echo 'VERSION=\"build 105\"'; exit 0")
        let up = NicotinePod(curl: curlOK, ssh: sshOK)
        let reachable = await up.isReachable()
        XCTAssertTrue(reachable)
        let info = try await up.info()
        XCTAssertEqual(info.versionLine, "Nicotine (Doof Different) — build 105")

        let curlDown = try install("curl-down", "exit 7")
        let down = NicotinePod(curl: curlDown, ssh: sshOK)
        let waited = await down.waitUntilReachable(timeoutSeconds: 0)
        XCTAssertFalse(waited)
    }

    // MARK: saved settings

    func testSettingsRunTheScriptInTheFolder() async throws {
        XCTAssertEqual(NicotineSettings.Action.save.arguments, ["save"])
        XCTAssertEqual(NicotineSettings.Action.restore(waitSeconds: 90).arguments, ["restore", "--wait", "90"])
        XCTAssertEqual(NicotineSettings.Action.status.arguments, ["status"])

        let layout = try makeLayout()
        // No script yet: a clear error, nothing run.
        do {
            _ = try await NicotineSettings(layout: layout).run(.status, onLog: { _ in })
            XCTFail("there is no homepod-config.sh")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("homepod-config.sh"))
        }

        try "#!/bin/bash\necho \"homepod-config: $* in $(basename \"$PWD\")\"\n[ \"$1\" = save ] && exit 1\nexit 0\n"
            .write(to: layout.configScript, atomically: true, encoding: .utf8)
        let log = Lines()
        let ok = try await NicotineSettings(layout: layout).run(.restore(waitSeconds: 5), onLog: { log.add($0) })
        XCTAssertEqual(ok.exitCode, 0)
        // (Filtered: a shell may add its own warnings, e.g. about the locale.)
        XCTAssertEqual(log.all.filter { $0.hasPrefix("homepod-config:") }, ["homepod-config: restore --wait 5 in linux-homepod"])
        let failed = try await NicotineSettings(layout: layout).run(.save, onLog: { _ in })
        XCTAssertEqual(failed.exitCode, 1)

        try FileManager.default.createDirectory(at: layout.configDir, withIntermediateDirectories: true)
        try Data().write(to: layout.configDir.appendingPathComponent("homepod-config-7096.tar.gz"))
        try Data().write(to: layout.configDir.appendingPathComponent("homepod-config-7096.tar.gz.prev"))
        XCTAssertEqual(layout.savedBackups.map(\.lastPathComponent), ["homepod-config-7096.tar.gz"])
    }

    func testEveryNicotineErrorHasAnExplanation() {
        let errors: [NicotineError] = [
            .folderMissing(""), .filesMissing(folder: "/N", files: ["img4/x"]), .toolMissing("gaster"),
            .stepFailed(command: "gaster pwn", exitCode: 1),
            .stepFailed(command: "irecovery -f iBSS.dev-hoolock.img4", exitCode: 1),
            .stepFailed(command: "irecovery -f RestoreKernelCache_m1n1-linux.img4", exitCode: 1),
        ]
        for e in errors {
            XCTAssertNotNil(e.issue, "\(e)")
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
        XCTAssertNotNil(ErrorCatalog.nicotineIssue("nicotine.nonetwork"))
        XCTAssertEqual(Set(ErrorCatalog.nicotine.map(\.id)).count, ErrorCatalog.nicotine.count)
        // None of these may ever match a restore log line.
        XCTAssertTrue(ErrorCatalog.nicotine.allSatisfy { $0.patterns.isEmpty })
    }
}
