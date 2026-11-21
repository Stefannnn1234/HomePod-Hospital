import XCTest
@testable import HomePodRestoreCore

/// Where the Nicotine boot files come from (picked folder, app bundle, import),
/// the MANIFEST check before a boot, importing a folder or a .zip, and where
/// the settings backups go. Everything happens in a temporary folder.
final class NicotinePayloadTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nicotine-payload-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: helpers

    static let allFiles = NicotinePayloadVerifier.requiredFiles + ["boot-linux.sh", "homepod-config.sh", "README-FIRST.txt"]

    /// A payload folder in the published layout: eight files and a MANIFEST
    /// with four header lines, as the real one has.
    @discardableResult
    func makePayload(_ name: String, build: String = "107", manifest: Bool = true,
                     omit: [String] = [], extraHeader: [String] = []) throws -> URL {
        let root = tmp.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("img4"), withIntermediateDirectories: true)
        var lines = [NicotineManifest.magic, "build=\(build)", "variant=public", "created=2026-11-21T08:10:00Z"] + extraHeader
        for path in Self.allFiles {
            let body = Data("contents of \(path) in \(name), build \(build)\n".utf8)
            if !omit.contains(path) { try body.write(to: root.appendingPathComponent(path)) }
            lines.append(NicotineHash.plainSHA256Hex(body) + "  " + path)
        }
        if manifest {
            try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent(NicotineManifest.fileName),
                                                               atomically: true, encoding: .utf8)
        }
        return root
    }

    func assertThrows(_ expected: NicotineError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let e as NicotineError {
            XCTAssertEqual(e, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: SHA-256

    func testPlainSHA256MatchesKnownVectors() throws {
        XCTAssertEqual(NicotineHash.plainSHA256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(NicotineHash.plainSHA256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(NicotineHash.plainSHA256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // A million "a", fed through the file path in uneven pieces.
        let big = tmp.appendingPathComponent("million-a")
        try Data(repeating: 0x61, count: 1_000_000).write(to: big)
        XCTAssertEqual(try NicotineHash.sha256Hex(of: big),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    // MARK: MANIFEST

    func testManifestParsing() throws {
        let h = String(repeating: "ab", count: 32)
        let text = """
        nicotine-payload 1
        build=107
        variant=public
        created=2026-11-21T08:10:00Z
        some-future-key=whatever = it says
        \(h)  img4/iBSS.dev-hoolock.img4
        \(h.uppercased()) *./boot-linux.sh

        """
        let m = try NicotineManifest.parse(text)
        XCTAssertEqual(m.build, "107")
        XCTAssertEqual(m.variant, "public")
        XCTAssertEqual(m.created, "2026-11-21T08:10:00Z")
        XCTAssertEqual(m.header["some-future-key"], "whatever = it says")       // unknown keys are kept, not fatal
        XCTAssertEqual(m.entries, [.init(sha256: h, path: "img4/iBSS.dev-hoolock.img4"), .init(sha256: h, path: "boot-linux.sh")])
        XCTAssertEqual(m.summary, "build 107 (public)")

        for bad in ["", "something else\nbuild=1\n", "nicotine-payload 2\n\(h)  a\n", NicotineManifest.magic + "\nbuild=1\n",
                    NicotineManifest.magic + "\n\(h)  ../outside\n", NicotineManifest.magic + "\n\(h)  /etc/passwd\n",
                    NicotineManifest.magic + "\n\(h)  a\n\(h)  a\n", NicotineManifest.magic + "\nnot a line\n"] {
            XCTAssertThrowsError(try NicotineManifest.parse(bad), bad) { XCTAssertTrue($0 is NicotineError) }
        }
        XCTAssertTrue(NicotineManifest.isSafe(relativePath: "img4/x.img4"))
        for p in ["", "/x", "../x", "a/../x", "a//b", "./x", "~/x", "a\\b"] {
            XCTAssertFalse(NicotineManifest.isSafe(relativePath: p), p)
        }
    }

    func testVerifyAcceptsAGoodPayloadAndNamesTheDamage() throws {
        let root = try makePayload("good")
        let m = try XCTUnwrap(try NicotinePayloadVerifier.verify(root: root))
        XCTAssertEqual(m.entries.count, 8)
        XCTAssertEqual(m.build, "107")

        // A truncated image: the likely real-world failure.
        let image = root.appendingPathComponent("img4/RestoreKernelCache_m1n1-linux.img4")
        try Data("contents of".utf8).write(to: image)
        assertThrows(.checksumMismatch(file: "img4/RestoreKernelCache_m1n1-linux.img4")) { try NicotinePayloadVerifier.verify(root: root) }

        // A listed file that isn't there (any listed file, not only a boot file).
        let missing = try makePayload("missing", omit: ["README-FIRST.txt"])
        assertThrows(.payloadFileMissing("README-FIRST.txt")) { try NicotinePayloadVerifier.verify(root: missing) }

        // A manifest that doesn't cover the boot files is not a payload manifest.
        let partial = try makePayload("partial")
        let kept = try String(contentsOf: partial.appendingPathComponent("MANIFEST"), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.contains("iBEC") }.joined(separator: "\n")
        try kept.write(to: partial.appendingPathComponent("MANIFEST"), atomically: true, encoding: .utf8)
        assertThrows(.manifestInvalid("it doesn't list img4/iBEC.dev-hoolock.img4")) { try NicotinePayloadVerifier.verify(root: partial) }

        // No MANIFEST at all (a developer's image folder): nothing to check, not an error.
        let bench = try makePayload("bench", manifest: false)
        XCTAssertNil(try NicotinePayloadVerifier.verify(root: bench))
    }

    func testBootRefusesADamagedPayloadBeforeTouchingTheHomePod() async throws {
        let root = try makePayload("payload")
        let marker = tmp.appendingPathComponent("gaster-ran")
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var tools: [URL] = []
        for name in ["gaster", "irecovery"] {
            let u = bin.appendingPathComponent(name)
            try "#!/bin/bash\ntouch '\(marker.path)'\nexit 0\n".write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
            tools.append(u)
        }
        let layout = NicotineLayout(root: root)
        let booter = NicotineBooter(config: .init(layout: layout, gaster: tools[0], irecovery: tools[1], pauseScale: 0))

        // intact: preflight passes and the boot runs
        XCTAssertNoThrow(try booter.preflight())

        // damaged: refused, and neither tool was started
        try Data("short".utf8).write(to: layout.kernelCache)
        do {
            try await booter.boot(onLog: { _ in })
            XCTFail("a damaged payload must not boot")
        } catch let e as NicotineError {
            XCTAssertEqual(e, .checksumMismatch(file: "img4/RestoreKernelCache_m1n1-linux.img4"))
            XCTAssertEqual(e.issue?.id, "nicotine.damaged")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: lookup order

    func testLookupOrder() throws {
        let chosen = try makePayload("chosen", manifest: false)
        let bundled = try makePayload("bundled")
        let imported = try makePayload("imported", build: "108")
        let nowhere = tmp.appendingPathComponent("nowhere", isDirectory: true)

        // 1. the picked folder wins
        var p = try XCTUnwrap(NicotinePayloadLocator.resolve(chosen: chosen, bundled: bundled, imported: imported))
        XCTAssertEqual(p.source, .chosen)
        XCTAssertEqual(p.layout.root, chosen)
        XCTAssertNil(p.manifest)

        // 2. no picked folder (or one that is gone): the one in the app
        for c in [nil, nowhere] as [URL?] {
            p = try XCTUnwrap(NicotinePayloadLocator.resolve(chosen: c, bundled: bundled, imported: imported))
            XCTAssertEqual(p.source, .bundled)
            XCTAssertEqual(p.manifest?.build, "107")
        }

        // 3. an app built without a payload: the imported one
        p = try XCTUnwrap(NicotinePayloadLocator.resolve(chosen: nil, bundled: nowhere, imported: imported))
        XCTAssertEqual(p.source, .imported)
        XCTAssertEqual(p.manifest?.summary, "build 108 (public)")
        p = try XCTUnwrap(NicotinePayloadLocator.resolve(chosen: nil, bundled: nil, imported: imported))
        XCTAssertEqual(p.source, .imported)

        // a picked folder that exists but is incomplete is still the one in use (and reports what it lacks)
        let broken = try makePayload("broken", manifest: false, omit: ["img4/iBSS.dev-hoolock.img4"])
        p = try XCTUnwrap(NicotinePayloadLocator.resolve(chosen: broken, bundled: bundled, imported: imported))
        XCTAssertEqual(p.source, .chosen)
        XCTAssertEqual(p.layout.missingBootFiles, ["img4/iBSS.dev-hoolock.img4"])

        // an incomplete bundled payload is skipped for a complete imported one …
        let halfBundled = try makePayload("half-bundled", omit: ["img4/RestoreTrustCache.img4"])
        p = try XCTUnwrap(NicotinePayloadLocator.resolve(chosen: nil, bundled: halfBundled, imported: imported))
        XCTAssertEqual(p.source, .imported)
        // … but shown when it is all there is
        p = try XCTUnwrap(NicotinePayloadLocator.resolve(chosen: nil, bundled: halfBundled, imported: nowhere))
        XCTAssertEqual(p.source, .bundled)
        XCTAssertFalse(p.layout.isComplete)

        // nothing anywhere: a fresh Mac with an app built without a payload
        XCTAssertNil(NicotinePayloadLocator.resolve(chosen: nil, bundled: nowhere, imported: nowhere))
        XCTAssertNil(NicotinePayloadLocator.resolve(chosen: nil, bundled: nil, imported: nil))

        XCTAssertEqual(NicotinePayloadLocator.bundledRoot(resources: URL(fileURLWithPath: "/A/B.app/Contents/Resources"))?.path,
                       "/A/B.app/Contents/Resources/Nicotine")
        XCTAssertEqual(NicotinePayloadLocator.importedRoot.lastPathComponent, "Nicotine")
        XCTAssertEqual(NicotinePayloadLocator.settingsDirectory.lastPathComponent, "Nicotine Settings")
        XCTAssertTrue(NicotinePayloadImporter.payloadDownloadURL.isEmpty, "no download address is built in")
    }

    // MARK: import

    func testImportFromAFolder() async throws {
        let source = try makePayload("download")
        // things a payload folder may have next to it that must NOT come along
        try FileManager.default.createDirectory(at: source.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: source.appendingPathComponent("config/homepod-config-7096.tar.gz"))
        try Data("x".utf8).write(to: source.appendingPathComponent("img4/RestoreKernelCache_m1n1-linux-build105-fallback.img4"))

        let dest = tmp.appendingPathComponent("Support/Nicotine", isDirectory: true)
        let m = try await NicotinePayloadImporter.install(from: source, to: dest)
        XCTAssertEqual(m.build, "107")
        XCTAssertNotNil(try NicotinePayloadVerifier.verify(root: dest))
        XCTAssertTrue(NicotineLayout(root: dest).isComplete)
        XCTAssertTrue(NicotineLayout(root: dest).hasConfigScript)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.appendingPathComponent("homepod-config.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("config").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent("img4").path).count, 5)

        // a newer payload replaces it completely
        let newer = try makePayload("newer", build: "108")
        _ = try await NicotinePayloadImporter.install(from: newer, to: dest)
        XCTAssertEqual(try NicotineManifest.load(from: dest)?.build, "108")

        // a damaged one is refused and the installed payload stays as it was
        let damaged = try makePayload("damaged", build: "109")
        try Data("cut".utf8).write(to: damaged.appendingPathComponent("img4/RestoreKernelCache_m1n1-linux.img4"))
        do {
            _ = try await NicotinePayloadImporter.install(from: damaged, to: dest)
            XCTFail("a damaged payload must not be installed")
        } catch let e as NicotineError {
            XCTAssertEqual(e, .checksumMismatch(file: "img4/RestoreKernelCache_m1n1-linux.img4"))
        }
        XCTAssertEqual(try NicotineManifest.load(from: dest)?.build, "108")
        XCTAssertNotNil(try NicotinePayloadVerifier.verify(root: dest))

        // a folder that is no payload at all
        let bench = try makePayload("bench", manifest: false)
        do {
            _ = try await NicotinePayloadImporter.install(from: bench, to: dest)
            XCTFail("no MANIFEST, no import")
        } catch let e as NicotineError {
            guard case .importFailed(let why) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(why.contains("MANIFEST"))
        }
        // no work folders left behind next to the payload
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["Nicotine"])
    }

    func testImportFromAZip() async throws {
        let zipTool = URL(fileURLWithPath: "/usr/bin/zip")
        let unzipTool = URL(fileURLWithPath: "/usr/bin/unzip")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: zipTool.path)
                          && FileManager.default.isExecutableFile(atPath: unzipTool.path), "zip/unzip not installed")
        let dest = tmp.appendingPathComponent("Support/Nicotine", isDirectory: true)

        // the usual shape: one folder at the top of the archive (what make-nicotine-payload.sh makes)
        try makePayload("Nicotine-107")
        let nested = tmp.appendingPathComponent("Nicotine-107.zip")
        var r = try await ProcessRunner(executable: zipTool, arguments: ["-q", "-r", nested.path, "Nicotine-107"],
                                        currentDirectory: tmp).run(onLine: { _ in })
        XCTAssertEqual(r.exitCode, 0)
        var m = try await NicotinePayloadImporter.install(from: nested, to: dest, unzip: unzipTool)
        XCTAssertEqual(m.build, "107")
        XCTAssertNotNil(try NicotinePayloadVerifier.verify(root: dest))

        // files at the top of the archive
        let flatSource = try makePayload("flat", build: "108")
        let flat = tmp.appendingPathComponent("flat.zip")
        r = try await ProcessRunner(executable: zipTool, arguments: ["-q", "-r", flat.path, "."],
                                    currentDirectory: flatSource).run(onLine: { _ in })
        XCTAssertEqual(r.exitCode, 0)
        m = try await NicotinePayloadImporter.install(from: flat, to: dest, unzip: unzipTool)
        XCTAssertEqual(m.build, "108")

        // a cut-off download
        let whole = try Data(contentsOf: nested)
        let cut = tmp.appendingPathComponent("cut.zip")
        try whole.prefix(whole.count / 2).write(to: cut)
        do {
            _ = try await NicotinePayloadImporter.install(from: cut, to: dest, unzip: unzipTool)
            XCTFail("a truncated zip must not be installed")
        } catch {
            XCTAssertTrue(error is NicotineError, "\(error)")
        }
        XCTAssertEqual(try NicotineManifest.load(from: dest)?.build, "108")

        // not a zip, not a folder
        let other = tmp.appendingPathComponent("payload.dmg")
        try Data("x".utf8).write(to: other)
        do {
            _ = try await NicotinePayloadImporter.install(from: other, to: dest, unzip: unzipTool)
            XCTFail("only folders and .zip files")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(".zip"))
        }
    }

    // MARK: settings backups

    func testBackupsGoOutsideABundledOrImportedPayload() async throws {
        let root = try makePayload("payload")
        let settingsDir = tmp.appendingPathComponent("Support/Nicotine Settings", isDirectory: true)
        let layout = NicotineLayout(root: root)

        // a picked folder keeps the script's own default: config/ next to it
        let chosen = NicotinePayload(source: .chosen, layout: layout)
        XCTAssertNil(chosen.configDirectoryOverride(settingsDirectory: settingsDir))
        XCTAssertEqual(chosen.configDirectory(settingsDirectory: settingsDir), layout.configDir)
        XCTAssertNil(NicotineSettings(layout: layout).environment(base: [:])["HOMEPOD_CONFIG_DIR"])

        // bundled and imported payloads are never written into
        for source in [NicotinePayloadSource.bundled, .imported] {
            let p = NicotinePayload(source: source, layout: layout)
            XCTAssertEqual(p.configDirectoryOverride(settingsDirectory: settingsDir), settingsDir)
            XCTAssertEqual(p.configDirectory(settingsDirectory: settingsDir), settingsDir)
        }

        // the script really gets HOMEPOD_CONFIG_DIR, and the folder is made for it
        try "#!/bin/bash\necho \"homepod-config: dir=${HOMEPOD_CONFIG_DIR:-unset}\"\n: > \"${HOMEPOD_CONFIG_DIR}/homepod-config-7096.tar.gz\"\nexit 0\n"
            .write(to: layout.configScript, atomically: true, encoding: .utf8)
        let settings = NicotineSettings(layout: layout, configDirectory: settingsDir)
        XCTAssertEqual(settings.environment(base: ["PATH": "/bin"]), ["PATH": "/bin", "HOMEPOD_CONFIG_DIR": settingsDir.path])
        XCTAssertTrue(settings.savedBackups.isEmpty)
        let result = try await settings.run(.save, onLog: { _ in })
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("homepod-config: dir=\(settingsDir.path)"))
        XCTAssertEqual(settings.savedBackups.map(\.lastPathComponent), ["homepod-config-7096.tar.gz"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.configDir.path), "nothing may be written into the payload")
        // and with the real script back in place the payload still verifies: the run added nothing to it
        try "contents of homepod-config.sh in payload, build 107\n".write(to: layout.configScript, atomically: true, encoding: .utf8)
        XCTAssertNotNil(try NicotinePayloadVerifier.verify(root: root))
    }

    func testAutoRestoreDecisionAndOutcomes() {
        let backup = [URL(fileURLWithPath: "/S/homepod-config-7096.tar.gz")]
        XCTAssertTrue(NicotineSettings.shouldAutoRestore(enabled: true, hasScript: true, backups: backup))
        XCTAssertFalse(NicotineSettings.shouldAutoRestore(enabled: false, hasScript: true, backups: backup))
        XCTAssertFalse(NicotineSettings.shouldAutoRestore(enabled: true, hasScript: false, backups: backup))
        XCTAssertFalse(NicotineSettings.shouldAutoRestore(enabled: true, hasScript: true, backups: []),
                       "a fresh Mac has no backup: nothing is attempted and nothing looks like an error")

        let restore = NicotineSettings.Action.restore(waitSeconds: 0)
        // what homepod-config.sh prints, verbatim
        XCTAssertEqual(NicotineSettings.outcome(of: restore, exitCode: 0, output: """
            homepod-config: no backup for pod 7096 in /S; nothing to restore
            homepod-config: (make one with: ./homepod-config.sh save)
            """), .nothingToRestore)
        XCTAssertEqual(NicotineSettings.outcome(of: restore, exitCode: 0, output: """
            homepod-config: restoring pod 7096 from /S/homepod-config-7096.tar.gz ...
                wifi=applied
            homepod-config: restored
            """), .done("restored"))
        XCTAssertEqual(NicotineSettings.outcome(of: restore, exitCode: 3, output: """
                wifi=reverted
            homepod-config: restored, but one step did not go through (see the lines above)
            """), .partial("restored, but one step did not go through (see the lines above)"))
        XCTAssertEqual(NicotineSettings.outcome(of: restore, exitCode: 1, output: "homepod-config: the pod does not answer at http://172.16.42.1"),
                       .failed("the pod does not answer at http://172.16.42.1"))
        XCTAssertEqual(NicotineSettings.outcome(of: .save, exitCode: 0, output: """
            homepod-config: saved pod 7096 to /S/homepod-config-7096.tar.gz (2632 bytes)
                etc/hostname
            homepod-config: this file holds the WiFi key and the Bluetooth link keys; keep it private
            """), .done("saved pod 7096 to /S/homepod-config-7096.tar.gz (2632 bytes)"))
        XCTAssertEqual(NicotineSettings.outcome(of: .save, exitCode: 1, output: ""), .failed("The settings script failed."))
        XCTAssertTrue(NicotineSettings.Outcome.failed("x").isFailure)
        XCTAssertFalse(NicotineSettings.Outcome.nothingToRestore.isFailure)
        XCTAssertFalse(NicotineSettings.Outcome.partial("x").isFailure)
    }

    /// Against a real payload, when one is named:
    ///   NICOTINE_PAYLOAD_DIR=~/Downloads/diagsstuffnic/linux-homepod/public swift test --filter RealPayload
    /// (a folder or a Nicotine-<build>.zip). Skipped otherwise.
    func testRealPayloadVerifiesAndImports() async throws {
        let named = ProcessInfo.processInfo.environment["NICOTINE_PAYLOAD_DIR"] ?? ""
        try XCTSkipIf(named.isEmpty, "set NICOTINE_PAYLOAD_DIR to check a real payload")
        let source = URL(fileURLWithPath: (named as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), "\(source.path) isn't there")
        if isDir.boolValue {
            let m = try XCTUnwrap(try NicotinePayloadVerifier.verify(root: source), "the folder has no MANIFEST")
            XCTAssertNotNil(m.build)
            XCTAssertTrue(NicotineLayout(root: source).isComplete)
        }
        let dest = tmp.appendingPathComponent("Support/Nicotine", isDirectory: true)
        let m = try await NicotinePayloadImporter.install(from: source, to: dest)
        XCTAssertNotNil(try NicotinePayloadVerifier.verify(root: dest))
        let layout = NicotineLayout(root: dest)
        XCTAssertTrue(layout.isComplete)
        XCTAssertTrue(layout.hasConfigScript)
        // the settings script in a real payload must honour HOMEPOD_CONFIG_DIR
        let script = try String(contentsOf: layout.configScript, encoding: .utf8)
        XCTAssertTrue(script.contains("HOMEPOD_CONFIG_DIR"), "homepod-config.sh in this payload ignores HOMEPOD_CONFIG_DIR")
        print("real payload: \(m.summary), \(m.entries.count) files, image \(layout.imageDescription ?? "?")")
    }

    func testNewErrorsHaveExplanations() {
        let errors: [NicotineError] = [.manifestInvalid("it lists no files"), .payloadFileMissing("img4/x"),
                                       .checksumMismatch(file: "img4/x"), .importFailed("no")]
        for e in errors {
            XCTAssertEqual(e.issue?.id, "nicotine.damaged", "\(e)")
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
        XCTAssertTrue(NicotineError.checksumMismatch(file: "img4/RestoreKernelCache_m1n1-linux.img4").localizedDescription
            .contains("RestoreKernelCache_m1n1-linux.img4"))
    }
}
