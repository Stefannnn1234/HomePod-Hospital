import XCTest
@testable import HomePodRestoreCore

/// Puffin calibration templates, SysCfg calibration payloads, the factory
/// calibration comparison and the DIAGS command reference.
final class FactoryCalibrationTests: XCTestCase {

    // MARK: Payload builders (synthetic — no real unit's data in the repo)

    /// Little-endian 32-bit words. Negative values are stored the way the pod
    /// stores them: 16-bit two's complement in the low half of the word.
    static func payload(_ values: [Int]) -> Data {
        var d = Data()
        for v in values {
            let w = UInt32(UInt16(truncatingIfNeeded: v))
            d.append(contentsOf: [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8((w >> 24) & 0xFF)])
        }
        return d
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// One tweeter: overall gain, then low shelf, high shelf and three parametric bands.
    static func tweeterWords(_ n: Int) -> [Int] {
        [3 + n, 500, -96, 70, 12_000, -43, 70, 2_521, -76, 300, 1_259, 37, 187, 4_000, -32, 300]
    }

    static func speakerEQ(tweeters: Int = 7) -> Data {
        payload([1] + (0..<tweeters).flatMap(tweeterWords))
    }

    static let wooferEQ = payload([1, -61, 88, -50, 60, 101, -6, 100, 565, 13, 100])
    static let micGain = payload([1, 87, 73, 107, 103, 100, 76])
    static let speakerGain = payload([1, 140, 0, 0])

    /// A 'BLOB' container with `sections` sections of 100 bytes each.
    static func blobHeader(sections: Int, sectionBytes: Int = 100) -> Data {
        let headerBytes = 20 + 20 * sections
        var d = Data("BLOB".utf8)
        func append(_ v: Int) {
            d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        append(headerBytes); append(0x1234_5678); append(1); append(sections)
        for n in 0..<sections {
            append(n + 1); append(headerBytes + n * sectionBytes); append(sectionBytes); append(0x2144_DF1C); append(0)
        }
        return d
    }

    static func audioBlob(_ tag: String, _ data: Data?, expected: Int, blank: Bool = false) -> String {
        guard let data else { return #"{"tag":"\#(tag)","present":false,"expectedBytes":\#(expected)}"# }
        return #"{"tag":"\#(tag)","present":true,"bytes":\#(data.count),"expectedBytes":\#(expected),"inline":false,"blank":\#(blank),"version":1,"hex":"\#(hex(data))"}"#
    }

    static let topologyJSON = """
        [{"block":"socmca","role":"SoC I2S/TDM ports","required":true,"found":true,"nodes":3,"driversAttached":0,"names":["mca2","mca3","mca4"]},\
        {"block":"ampcontroller","role":"amp controller MCU","required":true,"found":true,"nodes":1,"driversAttached":0,"names":["aeac-mcu0"]},\
        {"block":"amp-data","role":"speaker TDM link","required":true,"found":true,"nodes":1,"driversAttached":0,"names":["audio-nitro"]},\
        {"block":"codec0","role":"mic codec 0","required":true,"found":true,"nodes":1,"driversAttached":1,"names":["audio-codec0"]},\
        {"block":"codec1","role":"mic codec 1","required":true,"found":true,"nodes":1,"driversAttached":1,"names":["audio-codec1"]},\
        {"block":"codec2","role":"mic codec 2","required":false,"found":false,"nodes":0,"driversAttached":0,"names":[]}]
        """

    /// What the current `hpdiag-audio` prints.
    static func audioJSON(speakerEQ: Data? = FactoryCalibrationTests.speakerEQ(), wooferEQ: Data? = FactoryCalibrationTests.wooferEQ,
                          micGain: Data? = FactoryCalibrationTests.micGain, speakerGain: Data? = FactoryCalibrationTests.speakerGain,
                          topology: String = FactoryCalibrationTests.topologyJSON, verdict: String = "pass") -> String {
        let cal = [audioBlob("SpEQ", speakerEQ, expected: 452), audioBlob("WFEQ", wooferEQ, expected: 44),
                   audioBlob("MiGa", micGain, expected: 28), audioBlob("SpGa", speakerGain, expected: 16)].joined(separator: ",")
        return #"{"tool":"audio","ok":true,"verdict":"\#(verdict)","codecDetected":true,"ampNodes":["aeac-mcu0","audio-nitro"],"amps":[],"audibleTest":false,"topology":\#(topology),"calibration":[\#(cal)],"calibrationSource":"AppleDiagnosticDataAccessReadOnly"}"#
    }

    static func radioJSON(wifiSections: Int? = 6, btSections: Int? = 3) -> String {
        func blob(_ tag: String, _ sections: Int?, dt: String) -> String {
            guard let sections else { return #"{"tag":"\#(tag)","present":false}"# }
            let header = blobHeader(sections: sections)
            let bytes = header.count + sections * 100
            return #"{"tag":"\#(tag)","present":true,"bytes":\#(bytes),"blank":false,"magic":"BLOB","headerBytes":\#(header.count),"version":1,"sections":\#(sections),"header":"\#(hex(header))","containerValid":true,"dtProperty":"\#(dt)","dtBytes":\#(bytes),"dtZero":false,"dtMatches":true}"#
        }
        return #"{"tool":"radio","ok":true,"verdict":"pass","wifi":{"present":true,"driver":"AppleBCMWLANCore","mac":"02:aa:bb:cc:dd:01","matchesSysCfg":true},"bt":{"present":true,"mac":"02:aa:bb:cc:dd:02","matchesSysCfg":true},"calibration":{"wifi":\#(blob("WCAL", wifiSections, dt: "wifi-calibration-msf")),"bt":\#(blob("BCAL", btSections, dt: "bluetooth-taurus-calibration"))}}"#
    }

    static let factoryJSON = """
        {"tool":"factory","ok":true,"sysCfgSig":"gfCS","sysCfgBytes":131072,\
        "tagsPresent":["SrNm","WMac","BMac","EMac","Mod#","Regn","RMd#","MLB#","SpEQ","SpGa","WFEQ","MiGa","WCAL","BCAL","LEDc","LSCI","MdlC"],\
        "tagsMissing":[],"lockers":[],"verdict":"pass"}
        """

    static func report(audio: String? = FactoryCalibrationTests.audioJSON(), radio: String? = FactoryCalibrationTests.radioJSON(),
                       factory: String? = FactoryCalibrationTests.factoryJSON) throws -> FullDiagnosticsReport {
        var results: [DiagToolResult] = []
        if let factory { results.append(try DiagParsers.parse(.factory, output: factory)) }
        if let radio { results.append(try DiagParsers.parse(.radio, output: radio)) }
        if let audio { results.append(try DiagParsers.parse(.audio, output: audio)) }
        return FullDiagnosticsReport(serial: "SERIAL000001", timestamp: Date(timeIntervalSince1970: 1_794_690_000), results: results)
    }

    // MARK: Templates

    func testSpeakerTemplateIsOneWooferAndSevenTweeters() {
        let t = PuffinSpeakerCalibrationTemplate.factory
        XCTAssertEqual(t.driverCount, 8)
        XCTAssertEqual(t.woofers.count, 1)
        XCTAssertEqual(t.tweeters.count, 7)
        XCTAssertEqual(t.speakers.map(\.boxName), ["wooferTrim", "trim0", "trim1", "trim2", "trim3", "trim4", "trim5", "trim6"])
        XCTAssertEqual(t.woofers[0].bandCount, 3)
        XCTAssertEqual(t.woofers[0].filters, [.resonantLowShelf, .parametric, .parametric])
        for tweeter in t.tweeters {
            XCTAssertEqual(tweeter.bandCount, 5)
            XCTAssertEqual(tweeter.filters, [.resonantLowShelf, .resonantHighShelf, .parametric, .parametric, .parametric])
        }
        // AUNBandEQ parameter ids: bypass 1000+n, type 2000+n, freq 3000+n, gain 4000+n, bandwidth 5000+n.
        let band = t.tweeters[2].eq[3]
        XCTAssertEqual([band.bypass.parameterID, band.filterType.parameterID, band.frequency.parameterID,
                        band.decibelGain.parameterID, band.bandwidth.parameterID], [1003, 2003, 3003, 4003, 5003])
        XCTAssertTrue(band.isEnabled)
        XCTAssertTrue(band.filterType.isFixed)
        XCTAssertFalse(band.frequency.isFixed, "frequency comes from the unit's calibration, not the template")
        XCTAssertEqual(t.tweeters[2].overallDecibelGain, PuffinParameterRef(boxName: "trim2", parameterID: 0))
        XCTAssertEqual(PuffinDriverRole(boxName: "trim6"), .tweeter(6))
        XCTAssertEqual(PuffinDriverRole(boxName: "wooferTrim"), .woofer)
        XCTAssertNil(PuffinDriverRole(boxName: "intMicTrim"))
    }

    func testMicTemplateIsOneInternalAndSixFarField() {
        let t = PuffinMicCalibrationTemplate.factory
        XCTAssertEqual(t.micCount, 7)
        XCTAssertEqual(t.internalMics.map(\.boxName), ["intMicTrim"])
        XCTAssertEqual(t.farFieldMics.map(\.boxName), (0..<6).map { "extMicTrim\($0)" })
        XCTAssertEqual(t.mics[3].title, "Far-field mic 3")
    }

    func testTemplatesRoundTripThroughBinaryPlists() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let speakers = try encoder.encode(PuffinSpeakerCalibrationTemplate.factory)
        XCTAssertEqual(String(decoding: speakers.prefix(6), as: UTF8.self), "bplist")
        XCTAssertEqual(try PuffinSpeakerCalibrationTemplate(plist: speakers), .factory)
        XCTAssertEqual(try PuffinMicCalibrationTemplate(plist: try encoder.encode(PuffinMicCalibrationTemplate.factory)), .factory)
    }

    func testTemplateAcceptsRealAndIntegerParameterIDs() throws {
        // The shipped plist stores some ids as reals (1001.0).
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>Mics</key><array><dict><key>OverallDecibelGain</key>
            <dict><key>BoxName</key><string>intMicTrim</string><key>ParameterID</key><real>1001.0</real>
            <key>ParameterValue</key><integer>9</integer></dict></dict></array></dict></plist>
            """
        let t = try PuffinMicCalibrationTemplate(plist: Data(xml.utf8))
        XCTAssertEqual(t.mics[0].overallDecibelGain.parameterID, 1001)
        XCTAssertEqual(t.mics[0].overallDecibelGain.parameterValue, 9)
    }

    /// Checks the built-in templates against Apple's real files when the
    /// ProtoPod extract is on this machine (it is never shipped in the repo).
    func testBuiltInTemplatesMatchTheProtoPodPlists() throws {
        let env = ProcessInfo.processInfo.environment["HPR_PROTOPOD_EXTRACT"]
        let dir = URL(fileURLWithPath: env ?? (NSHomeDirectory() + "/Downloads/diagsstuffnic/protopod_extract"))
        let prefix = "Library__Audio__Plug-Ins__HAL__PuffinPlugin.driver__"
        func load(_ name: String) throws -> Data {
            let url = dir.appendingPathComponent(prefix + name)
            guard let data = try? Data(contentsOf: url) else { throw XCTSkip("ProtoPod extract not present at \(dir.path)") }
            return data
        }
        XCTAssertEqual(try PuffinSpeakerCalibrationTemplate(plist: try load("PuffinSpeakerCalibration.plist")), .factory)
        XCTAssertEqual(try PuffinMicCalibrationTemplate(plist: try load("PuffinMicCalibration.plist")), .factory)
        XCTAssertEqual(try PuffinPowerParameterMapping(plist: try load("PuffinPowerParameterMapping.plist")), .factory)
        let dsp = try PuffinDSPDatabase(plist: try load("PuffinDSPDatabase.plist"))
        XCTAssertEqual(dsp.board, "b238a")
        XCTAssertEqual(dsp.inputs.count, 5)
        XCTAssertEqual(dsp.outputs.count, 16)
        let wall = try XCTUnwrap(dsp.outputs.first { $0.name == "Stereo Left Wall" })
        XCTAssertEqual([wall.role, wall.position, wall.mode], ["stereoleft", "wall", "defa"])
        XCTAssertFalse(wall.isCalibration)
        XCTAssertEqual(wall.files.last, "HAL/b238a_speaker_lt_wall.austrip")
    }

    func testPowerMappingInterpolates() throws {
        let excursion = try XCTUnwrap(PuffinPowerParameterMapping.factory.curve(parameterID: "xlim"))
        XCTAssertEqual(excursion.value(atControlEffort: 0), 8)
        XCTAssertEqual(excursion.value(atControlEffort: 1), 5)
        XCTAssertEqual(excursion.value(atControlEffort: 2), 5)
        XCTAssertEqual(try XCTUnwrap(excursion.value(atControlEffort: 0.2)), 7.35, accuracy: 0.0001)
        XCTAssertEqual(PuffinPowerParameterMapping.factory.curves.count, 4)
    }

    // MARK: Unit calibration payloads

    func testExpectedSizesFollowFromTheTemplate() {
        XCTAssertEqual(PuffinCalibrationTag.speakerEQ.expectedBytes, 452)   // 4 + 7 × 16 × 4
        XCTAssertEqual(PuffinCalibrationTag.wooferEQ.expectedBytes, 44)     // 4 + 10 × 4
        XCTAssertEqual(PuffinCalibrationTag.micGain.expectedBytes, 28)      // 4 + 6 × 4
        XCTAssertEqual(PuffinCalibrationTag.speakerGain.expectedBytes, 16)
        XCTAssertEqual(Self.speakerEQ().count, 452)
        XCTAssertEqual(Self.wooferEQ.count, 44)
        XCTAssertEqual(Self.micGain.count, 28)
    }

    func testDecodesSpeakerAndWooferEQ() throws {
        let (version, tweeters) = try PuffinUnitCalibration.decodeSpeakerEQ(Self.speakerEQ())
        XCTAssertEqual(version, 1)
        XCTAssertEqual(tweeters.count, 7)
        XCTAssertEqual(tweeters.map(\.role), (0..<7).map { PuffinDriverRole.tweeter($0) })
        XCTAssertEqual(tweeters[4].overallGainRaw, 7)
        let first = tweeters[0].bands[0]
        XCTAssertEqual(first.frequencyHz, 500)
        XCTAssertEqual(first.gainRaw, -96, "A0 FF 00 00 is −96, not 65440")
        XCTAssertEqual(first.bandwidthRaw, 70)
        XCTAssertEqual(first.filter, .resonantLowShelf)
        XCTAssertEqual(tweeters[0].bands[1].filter, .resonantHighShelf)
        XCTAssertEqual(tweeters[0].bands[1].frequencyHz, 12_000)
        XCTAssertEqual(first.gainDB, -0.96, accuracy: 0.0001)
        XCTAssertEqual(first.summary, "LS 500 Hz −0.96 dB bw 0.70")
        XCTAssertEqual(tweeters[0].bands[3].summary, "PEQ 1259 Hz +0.37 dB bw 1.87")
        XCTAssertTrue(tweeters.allSatisfy(\.isPlausible))

        let (wv, woofer) = try PuffinUnitCalibration.decodeWooferEQ(Self.wooferEQ)
        XCTAssertEqual(wv, 1)
        XCTAssertEqual(woofer.role, .woofer)
        XCTAssertEqual(woofer.overallGainRaw, -61)
        XCTAssertEqual(woofer.bands.map(\.frequencyHz), [88, 101, 565])
        XCTAssertEqual(woofer.bands.map(\.gainRaw), [-50, -6, 13])
        XCTAssertEqual(woofer.bands.map(\.filter), [.resonantLowShelf, .parametric, .parametric])
    }

    func testDecodesMicAndSpeakerGain() throws {
        XCTAssertEqual(try PuffinUnitCalibration.decodeMicGain(Self.micGain).gains, [87, 73, 107, 103, 100, 76])
        XCTAssertEqual(try PuffinUnitCalibration.decodeSpeakerGain(Self.speakerGain).gain, 140)
    }

    func testBlankTruncatedAndRaggedPayloadsAreRejected() {
        XCTAssertThrowsError(try PuffinUnitCalibration.decodeSpeakerEQ(Data(repeating: 0xFF, count: 452))) {
            XCTAssertEqual($0 as? PuffinCalibrationError, .blank(tag: "SpEQ"))
        }
        XCTAssertThrowsError(try PuffinUnitCalibration.decodeWooferEQ(Data(repeating: 0, count: 44))) {
            XCTAssertEqual($0 as? PuffinCalibrationError, .blank(tag: "WFEQ"))
        }
        XCTAssertThrowsError(try PuffinUnitCalibration.decodeMicGain(Data([1, 0, 0]))) {
            XCTAssertEqual($0 as? PuffinCalibrationError, .truncated(tag: "MiGa", bytes: 3))
        }
        // One word short of a whole tweeter.
        XCTAssertThrowsError(try PuffinUnitCalibration.decodeSpeakerEQ(Self.speakerEQ().dropLast(4))) {
            XCTAssertEqual($0 as? PuffinCalibrationError, .unexpectedSize(tag: "SpEQ", bytes: 448, expected: 452))
        }
    }

    func testUnitCalibrationKeepsGoodPayloadsWhenOneIsBad() {
        let unit = PuffinUnitCalibration(payloads: [.speakerEQ: Self.speakerEQ(), .wooferEQ: Data(repeating: 0xFF, count: 44),
                                                    .micGain: Self.micGain])
        XCTAssertEqual(unit.tweeters.count, 7)
        XCTAssertNil(unit.woofer)
        XCTAssertEqual(unit.failures[.wooferEQ], .blank(tag: "WFEQ"))
        XCTAssertEqual(unit.micCount, 6)
        XCTAssertEqual(unit.driverCount, 7)
    }

    func testHexParsing() {
        XCTAssertEqual(PuffinUnitCalibration.data(hex: "01A0ff"), Data([0x01, 0xA0, 0xFF]))
        XCTAssertNil(PuffinUnitCalibration.data(hex: "0g"))
        XCTAssertNil(PuffinUnitCalibration.data(hex: "abc"))
    }

    // MARK: Script output → types

    func testAudioDecodesTopologyAndCalibration() throws {
        let audio = try DiagParsers.parseAudio(Self.audioJSON())
        XCTAssertEqual(audio.topology.count, 6)
        XCTAssertTrue(audio.missingBlocks.isEmpty, "codec2 is optional")
        XCTAssertEqual(audio.calibration.map(\.tag), ["SpEQ", "WFEQ", "MiGa", "SpGa"])
        XCTAssertEqual(audio.verdict, .pass)
        let unit = try XCTUnwrap(audio.unitCalibration)
        XCTAssertEqual(unit.driverCount, 8)
        XCTAssertEqual(unit.micCount, 6)
        XCTAssertEqual(unit.speakerGainRaw, 140)
        XCTAssertEqual(audio.rows.first { $0.id == "audio.chain" }?.value, "5 of 5 blocks answer")
        XCTAssertEqual(audio.rows.first { $0.id == "audio.tuning" }?.verdict, .pass)
    }

    func testAllDigitHexIsNotMistakenForANumber() throws {
        // A payload whose hex happens to contain no letters must stay a string.
        let data = Self.payload([1, 16, 32, 48])
        XCTAssertNil(Self.hex(data).first { $0.isLetter })
        let json = #"{"tool":"audio","ok":true,"calibration":[\#(Self.audioBlob("SpGa", data, expected: 16))]}"#
        XCTAssertEqual(try DiagParsers.parseAudio(json).calibration[0].payload, data)
    }

    func testMissingAmpControllerIsALeadNotAVerdict() throws {
        let topology = Self.topologyJSON.replacingOccurrences(
            of: #""block":"ampcontroller","role":"amp controller MCU","required":true,"found":true,"nodes":1"#,
            with: #""block":"ampcontroller","role":"amp controller MCU","required":true,"found":false,"nodes":0"#)
        let audio = try DiagParsers.parseAudio(Self.audioJSON(topology: topology))
        XCTAssertEqual(audio.missingBlocks.map(\.block), ["ampcontroller"])
        let row = try XCTUnwrap(audio.rows.first { $0.id == "audio.chain" })
        XCTAssertEqual(row.value, "4 of 5 blocks answer")
        XCTAssertEqual(row.verdict, .info)
        XCTAssertTrue(row.note?.contains("amp board") == true)
        XCTAssertEqual(audio.verdict, .pass, "presence of a node on this ramdisk isn't proven, so it never fails the tool")
    }

    func testMissingAudioCalibrationWarns() throws {
        let audio = try DiagParsers.parseAudio(Self.audioJSON(speakerEQ: nil, wooferEQ: Data(repeating: 0xFF, count: 44)))
        XCTAssertEqual(audio.unusableCalibration.map(\.tag), ["SpEQ"])
        XCTAssertEqual(audio.verdict, .warn)
        XCTAssertEqual(audio.rows.first { $0.id == "audio.tuning" }?.value, "SpEQ missing")
        // The script marks blank payloads itself; the Mac also catches one it didn't.
        let blank = try DiagParsers.parseAudio(#"{"tool":"audio","ok":true,"calibration":[\#(Self.audioBlob("WFEQ", Data(repeating: 0xFF, count: 44), expected: 44, blank: true))]}"#)
        XCTAssertEqual(blank.rows.first { $0.id == "audio.tuning" }?.value, "WFEQ blank")
    }

    func testOlderAudioScriptStillDecodes() throws {
        let audio = try DiagParsers.parseAudio(#"{"tool":"audio","ok":true,"codecDetected":true,"ampNodes":[],"amps":[],"verdict":"pass"}"#)
        XCTAssertTrue(audio.topology.isEmpty)
        XCTAssertTrue(audio.calibration.isEmpty)
        XCTAssertNil(audio.unitCalibration)
        XCTAssertNil(audio.rows.first { $0.id == "audio.chain" })
        XCTAssertNil(audio.rows.first { $0.id == "audio.tuning" })
    }

    func testRadioCalibration() throws {
        let radio = try DiagParsers.parseRadio(Self.radioJSON())
        XCTAssertEqual(radio.verdict, .pass)
        let wifi = try XCTUnwrap(radio.calibration?.wifi)
        XCTAssertEqual(wifi.sectionTable.count, 6)
        XCTAssertEqual(wifi.sectionTable[1], SysCfgCalibrationBlob.Section(type: 2, offset: 240, length: 100))
        XCTAssertEqual(wifi.sectionsInBounds, true)
        XCTAssertEqual(radio.rows.first { $0.id == "radio.wifi.calibration" }?.value, "WCAL · 740 bytes · 6 sections")
        XCTAssertEqual(radio.rows.first { $0.id == "radio.bt.calibration" }?.verdict, .pass)
        XCTAssertEqual(RadioStatus.Calibration.bluetoothChunks(forBytes: 1440), 7)

        let missing = try DiagParsers.parseRadio(Self.radioJSON(wifiSections: nil))
        XCTAssertEqual(missing.verdict, .warn)
        XCTAssertEqual(missing.rows.first { $0.id == "radio.wifi.calibration" }?.value, "WCAL missing")

        let bad = try DiagParsers.parseRadio(
            #"{"tool":"radio","ok":true,"calibration":{"bt":{"tag":"BCAL","present":true,"bytes":1440,"blank":false,"magic":"","containerValid":false}}}"#)
        XCTAssertEqual(bad.rows.first { $0.id == "radio.bt.calibration" }?.verdict, .warn)
    }

    func testRadioSectionOutsideTheBlobIsCaught() throws {
        let header = Self.blobHeader(sections: 3)
        // Claims 3 × 100 bytes of sections but the blob is only 200 bytes long.
        let json = #"{"tool":"radio","ok":true,"calibration":{"bt":{"tag":"BCAL","present":true,"bytes":200,"blank":false,"magic":"BLOB","headerBytes":80,"sections":3,"header":"\#(Self.hex(header))","containerValid":true}}}"#
        let radio = try DiagParsers.parseRadio(json)
        XCTAssertEqual(radio.calibration?.bt?.sectionsInBounds, false)
        XCTAssertEqual(radio.verdict, .warn)
    }

    func testNANDIdentity() throws {
        let json = #"{"tool":"nand","ok":true,"verdict":"pass","nandStatus":"Ready","vendor":"Toshiba","nandMarketingName":"15nm64Gb0C","chipId":"50504E010508","manufacturerId":"988260561902","firmwareVersion":"054849P_TB_1ZMLC","controllerUniqueId":"000006061198C9E047E045501060F464","numBus":2,"cePerBus":1,"diesPerChannel":1}"#
        let nand = try DiagParsers.parseNAND(json)
        // Decoded Mac-side when the script didn't.
        XCTAssertEqual(nand.ppn, true)
        XCTAssertEqual(nand.ppnVersion, "1.5.8")
        XCTAssertEqual(nand.jedecVendor, "Toshiba/Kioxia")
        XCTAssertEqual(nand.vendorMismatch, false)
        XCTAssertEqual(nand.chipEnables, 2)
        XCTAssertEqual(nand.rows.first { $0.id == "nand.chipEnables" }?.value, "2 (2 buses × 1 CE)")
        XCTAssertEqual(nand.rows.first { $0.id == "nand.uid" }?.value, "000006061198C9E047E045501060F464")
        XCTAssertEqual(nand.verdict, .pass, "identity never changes the verdict")

        let swapped = try DiagParsers.parseNAND(#"{"tool":"nand","ok":true,"vendor":"Toshiba","chipId":"AABBCC","manufacturerId":"2C8260561902"}"#)
        XCTAssertEqual(swapped.jedecVendor, "Micron")
        XCTAssertEqual(swapped.vendorMismatch, true)
        XCTAssertEqual(swapped.ppn, false)
        XCTAssertNil(swapped.ppnVersion)

        let report = FullDiagnosticsReport(serial: nil, results: [.nand(nand)])
        XCTAssertTrue(report.supportText().contains("NAND Unique ID: 000006…F464"))
        XCTAssertFalse(report.supportText().contains("1198C9E0"))
        XCTAssertTrue(report.supportText(redactIdentifiers: false).contains("000006061198C9E047E045501060F464"))
    }

    // MARK: Factory calibration comparison

    func testExpectation() {
        XCTAssertEqual(FactoryCalibrationExpectation.driverCount, 8)
        XCTAssertEqual(FactoryCalibrationExpectation.micCount, 7)
        XCTAssertEqual(FactoryCalibrationExpectation.storedMicTrims, 6)
        XCTAssertEqual(FactoryCalibrationExpectation.keys.map(\.tag), ["SpEQ", "WFEQ", "SpGa", "MiGa", "WCAL", "BCAL", "LEDc", "LSCI", "MdlC"])
        XCTAssertEqual(FactoryCalibrationExpectation.key("SpEQ")?.expectedBytes, 452)
    }

    func testFullyCalibratedUnit() throws {
        let cal = try XCTUnwrap(try Self.report().factoryCalibration)
        XCTAssertEqual(cal.verdict, .pass)
        XCTAssertTrue(cal.problemKeys.isEmpty)
        XCTAssertTrue(cal.uncheckedKeys.isEmpty)
        XCTAssertEqual(cal.driverCount, 8)
        XCTAssertEqual(cal.tweeterCount, 7)
        XCTAssertEqual(cal.wooferCount, 1)
        XCTAssertEqual(cal.micTrimCount, 6)
        XCTAssertTrue(cal.structureIssues.isEmpty)
        let rows = Dictionary(uniqueKeysWithValues: cal.rows.map { ($0.id, $0) })
        XCTAssertEqual(rows["factorycal.keys"]?.value, "9 of 9 present")
        XCTAssertEqual(rows["factorycal.drivers"]?.value, "8 of 8 calibrated (1 woofer + 7 tweeters)")
        XCTAssertEqual(rows["factorycal.mics"]?.value, "6 of 6 far-field trims stored")
        XCTAssertEqual(rows["factorycal.structure"]?.value, "Matches Apple's template")
        XCTAssertEqual(rows["factorycal.radio"]?.verdict, .pass)
        XCTAssertFalse(cal.rows.contains { $0.verdict == .warn || $0.verdict == .fail })
    }

    func testMissingTweeterEQ() throws {
        let cal = try XCTUnwrap(try Self.report(audio: Self.audioJSON(speakerEQ: nil)).factoryCalibration)
        XCTAssertEqual(cal.verdict, .warn)
        XCTAssertEqual(cal.state(of: "SpEQ"), .missing, "the audio script's own finding wins over the factory tag list")
        let rows = Dictionary(uniqueKeysWithValues: cal.rows.map { ($0.id, $0) })
        XCTAssertEqual(rows["factorycal.keys"]?.value, "8 of 9 present")
        XCTAssertEqual(rows["factorycal.key.SpEQ"]?.value, "Missing")
        XCTAssertTrue(rows["factorycal.key.SpEQ"]?.note?.contains("tweeters") == true)
        XCTAssertEqual(rows["factorycal.drivers"]?.value, "1 of 8 calibrated (1 woofer + 0 tweeters)")
        XCTAssertEqual(rows["factorycal.drivers"]?.verdict, .warn)
    }

    func testWrongDriverCountAndSize() throws {
        let cal = try XCTUnwrap(try Self.report(audio: Self.audioJSON(speakerEQ: Self.speakerEQ(tweeters: 6))).factoryCalibration)
        XCTAssertEqual(cal.driverCount, 7)
        let rows = Dictionary(uniqueKeysWithValues: cal.rows.map { ($0.id, $0) })
        XCTAssertEqual(rows["factorycal.drivers"]?.verdict, .warn)
        XCTAssertEqual(rows["factorycal.size.SpEQ"]?.value, "388 bytes")
        XCTAssertEqual(cal.verdict, .warn)
    }

    func testImplausibleValuesAreStructureIssues() throws {
        var words = [1] + (0..<7).flatMap(Self.tweeterWords)
        words[1 + 16 * 2 + 1] = 0              // tweeter 3, band 1 frequency 0 Hz
        let zeros = Self.payload([1] + Array(repeating: 0, count: 9) + [1])   // not blank, but no real values
        let cal = try XCTUnwrap(try Self.report(audio: Self.audioJSON(speakerEQ: Self.payload(words), wooferEQ: zeros)).factoryCalibration)
        XCTAssertEqual(cal.structureIssues.count, 2)
        XCTAssertTrue(cal.structureIssues.contains { $0.contains("Tweeter 3") && $0.contains("band 1 (0 Hz)") })
        XCTAssertEqual(cal.rows.first { $0.id == "factorycal.structure" }?.verdict, .warn)
    }

    func testFactoryTagListAloneGivesKeysButNoCounts() throws {
        let cal = try XCTUnwrap(try Self.report(audio: nil, radio: nil).factoryCalibration)
        XCTAssertNil(cal.driverCount)
        let rows = Dictionary(uniqueKeysWithValues: cal.rows.map { ($0.id, $0) })
        XCTAssertEqual(rows["factorycal.keys"]?.value, "9 of 9 present")
        XCTAssertEqual(rows["factorycal.drivers"]?.verdict, .info)
        XCTAssertEqual(rows["factorycal.drivers"]?.value, "Expected 8 (1 woofer + 7 tweeters)")
        XCTAssertEqual(cal.verdict, .pass)
    }

    func testNoCalibrationInformationMeansNoSection() throws {
        // An older factory script that only lists the identity tags.
        let old = #"{"tool":"factory","ok":true,"sysCfgSig":"gfCS","tagsPresent":["SrNm","WMac","BMac"],"tagsMissing":[]}"#
        XCTAssertNil(try Self.report(audio: nil, radio: nil, factory: old).factoryCalibration)
        XCTAssertNil(FullDiagnosticsReport(serial: nil, results: []).factoryCalibration)
    }

    func testComparisonDoesNotChangeTheOverallVerdict() throws {
        // Factory script reports every tag; audio script is an older revision.
        let report = try Self.report(audio: #"{"tool":"audio","ok":true,"codecDetected":true,"ampNodes":[],"amps":[],"verdict":"pass"}"#)
        XCTAssertEqual(report.overall, .pass)
        XCTAssertFalse(report.findings.contains { $0.id.hasPrefix("factorycal.") })
    }

    func testReportRoundTripsAndSupportTextHasTheSection() throws {
        let report = try Self.report()
        let back = try JSONDecoder().decode(FullDiagnosticsReport.self, from: try report.exportJSON())
        XCTAssertEqual(back, report)
        XCTAssertEqual(back.factoryCalibration, report.factoryCalibration)
        let text = report.supportText()
        XCTAssertTrue(text.contains("[Factory Calibration]"))
        XCTAssertTrue(text.contains("Speaker Drivers: 8 of 8 calibrated"))
    }

    // MARK: DIAGS command reference

    func testReferenceCoversTheDocumentedCommands() {
        let wanted = ["syscfg", "sn", "audio", "playaudio", "recordaudio", "loopaudio", "stopaudio", "wifi", "bluetooth",
                      "nand", "nandcsid", "nanduid", "NANDInfoTool", "nandsize", "sensor", "temperature", "thermalmonitor",
                      "ampcontroller", "strobe", "button", "buttoncnt", "key", "mbt", "pmuadc", "pmutemp", "pmustat", "pmureg",
                      "sysinfo", "system", "version", "chipid", "boardid", "boardrev", "blockdevice",
                      "nandppnfwver", "spkid", "getvol", "setvol", "help",
                      "soc", "bootcfg", "device", "cbreadall", "cbdump", "pmuevent", "buckcheck", "rtc",
                      "memory", "dumpmemmap", "dir", "nvram"]
        for name in wanted { XCTAssertNotNil(DiagsCommandReference.command(named: name), name) }
        let names = DiagsCommandReference.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "command names are unique")
        XCTAssertEqual(DiagsCommandReference.command(named: " SYSCFG ")?.name, "syscfg")
        for category in DiagsCommand.Category.allCases {
            XCTAssertFalse(DiagsCommandReference.commands(in: category).isEmpty, category.title)
        }
    }

    func testOnlyConfirmedCommandsCarrySyntax() {
        for command in DiagsCommandReference.all {
            if command.source.isConfirmed {
                XCTAssertFalse(command.syntax.isEmpty, "\(command.name) is confirmed but has no usage")
            } else {
                XCTAssertTrue(command.syntax.isEmpty, "\(command.name): no usage has been captured, so none may be shown")
                XCTAssertTrue(command.examples.isEmpty, command.name)
            }
        }
    }

    func testRecipesAreTheFactoryScriptsVerbatim() throws {
        let tuxedo = """
            audio -b socmca
            audio -b ampcontroller
            audio -b codec0
            audio -b codec1
            audio -b codec2
            socgpio --pin 114 --output 0
            socgpio --pin 116 --output 1
            socgpio --pin 115 --output 0
            socgpio --pin 115 --output 1
            routeaudio -b ampcontroller -i spk-tdm -o spk-out -r
            routeaudio -b codec0 -i mic-in -o pcm-out -r
            routeaudio -b codec1 -i mic-in -o pcm-out -r
            routeaudio -b codec2 -i mic-in -o pcm-out -r
            """
        let reset = try XCTUnwrap(DiagsCommandReference.recipes.first { $0.title.hasPrefix("Reset the audio chain") })
        XCTAssertEqual(reset.steps, tuxedo.split(separator: "\n").map(String.init))
        let mlb = try XCTUnwrap(DiagsCommandReference.recipes.first { $0.title.hasPrefix("Clock the I2S") })
        XCTAssertEqual(mlb.steps.first, "audio -b socmca")
        XCTAssertEqual(mlb.steps.last, "audioparam -b socmca -p ap-mca3 -s -n master-lrclk-enable -v true")
        // Every recipe step starts with a command the card documents.
        for recipe in DiagsCommandReference.recipes {
            for step in recipe.steps { XCTAssertNotNil(DiagsCommandReference.command(forLine: step), step) }
        }
    }

    func testLineRiskDistinguishesReadsFromWrites() {
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "syscfg list"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "syscfg print WCAL"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "syscfg init"), .writesFlash)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "syscfg add SrNm ABC"), .writesFlash)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "syscfg delete SpEQ"), .writesFlash)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "syscfg frobnicate"), .writesFlash, "an unknown subcommand is assumed to write")
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "sn"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "sn ABC123"), .writesFlash)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "temperature --all"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "audio -b codec0"), .changesState)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "nanduid"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "pmureg"), .readOnly, "bare, it dumps every register")
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "pmureg 0x10 0x01"), .unknown, "with arguments it may write")
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "nand --testlist"), .readOnly, "lists the tests, runs none")
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "nand --getinfo"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "nand --test 3"), .unknown, "a NAND test may write")
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "nvram -p"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "nvram boot-args=x"), .unknown)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "device -l"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "cbreadall"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "pmuevent all"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "dir nandfs:"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "strobe -c led -s All_RGB --set blue 25"), .changesState)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "syscfg delete Mod#"), .writesFlash)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "NANDInfoTool"), .crashesDevice, "panics DIAGS on a real unit")
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "nandinfotool"), .crashesDevice)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "ampcontroller --init"), .changesState)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "ampcontroller -s [TEMP]"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "playaudio --listcaps"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "playaudio -o"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "playaudio"), .changesState)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "playaudio -b socmca -t 1000 -l 3000 -r 48000 -d 16"), .changesState)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "playaudio -b socmca -o -t 1000"), .changesState, "only a bare --listcaps is a read")
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "stopaudio"), .changesState)
        XCTAssertEqual(DiagsCommandReference.toneLine(hz: 1000, ms: 3000), "playaudio -b socmca -p ap-mca3 -t 1000 -l 3000 -r 48000 -d 16")
        XCTAssertEqual(DiagsCommandReference.toneLabel(100), "100 Hz")
        XCTAssertEqual(DiagsCommandReference.toneLabel(10000), "10 kHz")
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "help wifi"), .readOnly)
        XCTAssertEqual(DiagsCommandReference.risk(ofLine: "pmutemp"), .readOnly)
        XCTAssertNil(DiagsCommandReference.risk(ofLine: "nosuchcommand"))
        XCTAssertNil(DiagsCommandReference.risk(ofLine: "   "))
    }

    func testSearchAndPlainText() {
        XCTAssertEqual(DiagsCommandReference.search("calload").map(\.name), ["wifi"])
        XCTAssertTrue(DiagsCommandReference.search("amp controller").contains { $0.name == "ampcontroller" })
        XCTAssertEqual(DiagsCommandReference.search("").count, DiagsCommandReference.all.count)
        XCTAssertTrue(DiagsCommandReference.search("zzzz").isEmpty)
        XCTAssertEqual(DiagsCommandReference.command(named: "temperature")?.ramdiskEquivalent, .thermal)
        let text = DiagsCommandReference.plainText()
        XCTAssertTrue(text.contains("== Audio =="))
        XCTAssertTrue(text.contains("syscfg  [Writes to flash]"))
        XCTAssertTrue(text.contains("NANDInfoTool  [DANGEROUS — crashes the pod]"))
        XCTAssertTrue(text.contains("Recipe: Reset the audio chain (assembled unit)"))
        XCTAssertTrue(text.contains(DiagsCommand.usageNotCaptured))
    }
}
