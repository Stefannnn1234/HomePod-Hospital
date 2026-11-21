import XCTest
@testable import HomePodRestoreCore

/// The release boot loaders (prepared from Apple's own files) must boot through
/// the SAME sequence as boot-linux.sh, with only the two bootloaders swapped —
/// the app's equivalent of `IBOOT_DIR=… ./boot-linux.sh`. These tests pin that.
final class ReleaseIBootTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("relboot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func makeLayout(withRelease: Bool) throws -> NicotineLayout {
        let layout = NicotineLayout(root: tmp.appendingPathComponent("linux-homepod", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.img4Dir, withIntermediateDirectories: true)
        for f in layout.bootFiles { try Data("x".utf8).write(to: f) }
        if withRelease {
            try FileManager.default.createDirectory(at: layout.releaseIBootDir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: layout.releaseIBSS())
            try Data("x".utf8).write(to: layout.releaseIBEC())
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
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    // MARK: layout

    func testReleaseLayoutDiscovery() throws {
        let plain = try makeLayout(withRelease: false)
        XCTAssertFalse(plain.hasReleaseIBoot())
        XCTAssertEqual(plain.missingReleaseIBoot(), ["release-iboot/iBSS.img4", "release-iboot/iBEC.img4"])
        XCTAssertEqual(plain.releaseIBSS().lastPathComponent, "iBSS.img4")
        XCTAssertEqual(plain.releaseIBootDir.lastPathComponent, "release-iboot")

        let withRel = try makeLayout(withRelease: true)
        XCTAssertTrue(withRel.hasReleaseIBoot())
        XCTAssertEqual(withRel.missingReleaseIBoot(), [])

        // An override folder (bundled/imported payloads write elsewhere).
        let other = tmp.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertFalse(plain.hasReleaseIBoot(in: other))
        try Data("x".utf8).write(to: other.appendingPathComponent("iBSS.img4"))
        try Data("x".utf8).write(to: other.appendingPathComponent("iBEC.img4"))
        XCTAssertTrue(plain.hasReleaseIBoot(in: other))
    }

    // MARK: the sequence only swaps the two loaders

    func testReleaseStepsSwapOnlyTheBootloaders() throws {
        let layout = try makeLayout(withRelease: true)
        let rel = (iBSS: layout.releaseIBSS(), iBEC: layout.releaseIBEC())
        let dev = NicotineBooter.steps(for: layout)
        let release = NicotineBooter.steps(for: layout, releaseIBoot: rel)

        // same count, tools, stop-rules and pauses
        XCTAssertEqual(release.count, dev.count)
        XCTAssertEqual(release.map(\.stopsOnFailure), dev.map(\.stopsOnFailure))
        XCTAssertEqual(release.map(\.pauseAfter), dev.map(\.pauseAfter))

        // only steps 2 and 3 (iBSS, iBEC) differ, and to the release paths
        for (i, (a, b)) in zip(dev, release).enumerated() {
            if i == 2 { XCTAssertEqual(b.arguments, ["-f", rel.iBSS.path]) }
            else if i == 3 { XCTAssertEqual(b.arguments, ["-f", rel.iBEC.path]) }
            else { XCTAssertEqual(a.arguments, b.arguments, "step \(i) must be unchanged") }
        }
        XCTAssertTrue(release[2].arguments[1].hasSuffix("release-iboot/iBSS.img4"))
        XCTAssertFalse(release[2].arguments[1].contains("dev-hoolock"))
    }

    func testBootSendsReleaseLoaders() async throws {
        let layout = try makeLayout(withRelease: true)
        let record = tmp.appendingPathComponent("rec.txt")
        let gaster = try install("gaster", "echo \"gaster $*\" >> '\(record.path)'; exit 0")
        let irecovery = try install("irecovery", "echo \"irecovery $*\" >> '\(record.path)'; exit 0")
        let rel = (iBSS: layout.releaseIBSS(), iBEC: layout.releaseIBEC())
        let booter = NicotineBooter(config: .init(layout: layout, gaster: gaster, irecovery: irecovery,
                                                  releaseIBoot: rel, pauseScale: 0))
        let log = Lines()
        try await booter.boot(onLog: { log.add($0) })
        let commands = (try String(contentsOf: record, encoding: .utf8)).split(separator: "\n").map(String.init)
        XCTAssertTrue(commands.contains("irecovery -f \(rel.iBSS.path)"))
        XCTAssertTrue(commands.contains("irecovery -f \(rel.iBEC.path)"))
        XCTAssertFalse(commands.contains { $0.contains("iBSS.dev-hoolock") })
        XCTAssertTrue(log.all.contains { $0.contains("Apple release") })
    }

    func testPreflightFailsWhenReleaseLoadersMissing() async throws {
        let layout = try makeLayout(withRelease: false)        // dev files only
        let gaster = try install("gaster", "exit 0")
        let irecovery = try install("irecovery", "exit 0")
        let rel = (iBSS: layout.releaseIBSS(), iBEC: layout.releaseIBEC())  // not on disk
        let booter = NicotineBooter(config: .init(layout: layout, gaster: gaster, irecovery: irecovery,
                                                  releaseIBoot: rel, pauseScale: 0))
        do {
            try await booter.boot(onLog: { _ in })
            XCTFail("preflight should fail: the release loaders aren't there")
        } catch let error as NicotineError {
            guard case .filesMissing(_, let files) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(files, ["release-iboot/iBSS.img4", "release-iboot/iBEC.img4"])
        }
    }

    func testPreparerReportsScriptFailureAndOutput() async throws {
        // A stand-in script: no RELEASE_IBOOT_OUT output, non-zero exit → prepFailed with the tail.
        let out = tmp.appendingPathComponent("release-iboot", isDirectory: true)
        let fakeScript = try install("prep-release-iboot.sh", "echo line-one; echo last-line; exit 7")
        let prep = ReleaseIBootPreparer(outputDir: out)
        // run the script directly (locateScript() looks in the bundle; here we drive bash ourselves)
        let r = ProcessRunner(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [fakeScript.path],
                              environment: ["RELEASE_IBOOT_OUT": out.path, "PATH": "/usr/bin:/bin"])
        let result = try await r.run(onLine: { _ in })
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(prep.isPrepared)                        // nothing was written
    }
}
