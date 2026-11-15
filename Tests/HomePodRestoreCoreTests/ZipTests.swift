import XCTest
@testable import HomePodRestoreCore

final class ZipTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ziptests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func python(_ code: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", code]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, out)
        return out
    }

    func testReadsZip64AndCopiesEntries() async throws {
        let src = dir.appendingPathComponent("donor.zip")
        // A zip64 archive (forced) with a deflated plist, a deflated "ramdisk", a stored file.
        try python("""
        import zipfile, os
        z = zipfile.ZipFile('\(src.path)', 'w', allowZip64=True)
        def add(name, data, method):
            zi = zipfile.ZipInfo(name, date_time=(2025,1,27,21,38,0)); zi.compress_type = method
            with z.open(zi, 'w', force_zip64=True) as f: f.write(data)
        add('BuildManifest.plist', b'<?xml version="1.0"?><plist version="1.0"><dict><key>BuildIdentities</key><array><dict><key>Info</key><dict><key>Variant</key><string>Customer Erase Install (IPSW)</string></dict><key>Manifest</key><dict><key>RestoreRamDisk</key><dict><key>Info</key><dict><key>Path</key><string>090-12345-678.dmg</string></dict></dict></dict></dict></array></dict></plist>' * 1, zipfile.ZIP_DEFLATED)
        add('090-12345-678.dmg', os.urandom(300000) + b'A' * 500000, zipfile.ZIP_DEFLATED)
        add('stored.bin', b'hello', zipfile.ZIP_STORED)
        z.close()
        """)
        let source = LocalFileSource(url: src)
        let zdir = try await ZipDirectory.read(from: source)
        XCTAssertEqual(zdir.entries.map(\.name), ["BuildManifest.plist", "090-12345-678.dmg", "stored.bin"])
        let stored = try XCTUnwrap(zdir.entry(named: "stored.bin"))
        let storedData = try await ZipDirectory.contents(of: stored, in: source)
        XCTAssertEqual(String(decoding: storedData, as: UTF8.self), "hello")

        // Copy two entries verbatim into a new small zip, like the donor builder does.
        let out = dir.appendingPathComponent("mini.ipsw")
        let writer = try ZipCopyWriter(url: out)
        for name in ["BuildManifest.plist", "090-12345-678.dmg"] {
            let e = try XCTUnwrap(zdir.entry(named: name))
            let raw = try await ZipDirectory.rawData(of: e, in: source)
            try await writer.add(e) { append in
                append(raw.prefix(1000)); append(raw.dropFirst(1000))
            }
        }
        try writer.finish()
        let check = try python("""
        import zipfile
        a = zipfile.ZipFile('\(src.path)'); b = zipfile.ZipFile('\(out.path)')
        assert b.testzip() is None
        assert b.namelist() == ['BuildManifest.plist', '090-12345-678.dmg'], b.namelist()
        for n in b.namelist(): assert a.read(n) == b.read(n), n
        print('ok')
        """)
        XCTAssertTrue(check.contains("ok"))

        // The copied manifest still resolves the ramdisk path (plist parse).
        let manifestRaw = try python("""
        import zipfile, sys; sys.stdout.write(zipfile.ZipFile('\(out.path)').read('BuildManifest.plist').decode())
        """)
        XCTAssertEqual(IPSWBuilder.donorRamdiskPath(Data(manifestRaw.utf8)), "090-12345-678.dmg")
    }

    func testRejectsNonZip() async throws {
        let f = dir.appendingPathComponent("x.ipsw")
        try Data(repeating: 7, count: 1000).write(to: f)
        do {
            _ = try await ZipDirectory.read(from: LocalFileSource(url: f))
            XCTFail("should throw")
        } catch ZipError.notAZip {}
    }

    /// Network test against Apple's CDN: reads the central directory of the
    /// 18.3 Apple TV HD IPSW (~4.8 GB) with a few Range requests.
    /// Run with HOMEPOD_NET_TESTS=1 swift test
    func testRemoteAppleTVDirectory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOMEPOD_NET_TESTS"] == "1")
        let donors = try FirmwareCatalog.decode(try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "atv", withExtension: "json", subdirectory: "Fixtures"))))
        let d = try XCTUnwrap(donors.first { $0.buildid == "22K557" })
        let src = HTTPRangeSource(url: d.url)
        let zdir = try await ZipDirectory.read(from: src)
        let bm = try XCTUnwrap(zdir.entry(named: "BuildManifest.plist"))
        XCTAssertGreaterThan(zdir.entries.count, 10)
        let raw = try await ZipDirectory.rawData(of: bm, in: src)
        XCTAssertEqual(raw.count, Int(bm.compressedSize))
        // Inflate with python (Foundation on Linux can't), then resolve the ramdisk.
        let tmp = dir.appendingPathComponent("bm.raw"); try raw.write(to: tmp)
        let xml = try python("import zlib,sys; sys.stdout.write(zlib.decompress(open('\(tmp.path)','rb').read(), -15).decode())")
        let path = try XCTUnwrap(IPSWBuilder.donorRamdiskPath(Data(xml.utf8)))
        let rd = try XCTUnwrap(zdir.entry(named: path))
        print("donor ramdisk:", path, rd.compressedSize, "bytes compressed; zip64 offset:", rd.localHeaderOffset)
        XCTAssertGreaterThan(rd.compressedSize, 10_000_000)
        let off = try await ZipDirectory.dataOffset(of: rd, in: src)
        XCTAssertGreaterThan(off, rd.localHeaderOffset)
    }
}
