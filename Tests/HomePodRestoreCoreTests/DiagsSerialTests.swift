import XCTest
@testable import HomePodRestoreCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A stand-in for the DIAGS shell on the far end of a pseudo-terminal, so the
/// real `SerialPort` code (termios, poll, partial reads, hang-up) is exercised
/// without hardware. The test opens `slavePath` as if it were the USB adapter.
private final class FakeDiagsShell {
    static let ecid = "00092951386A6F26"
    static let prompt = "[\(ecid)] :-) "

    let master: Int32
    let slavePath: String
    /// command → reply (without the prompt). `nil` reply = never answer.
    var replies: [String: String?] = [:]
    /// Echo typed commands back, like the real shell.
    var echo = true
    /// Write replies in pieces of this size with a short pause between them.
    var chunkSize = 0
    private(set) var received: [String] = []
    private let lock = NSLock()
    private var stopped = false
    private var thread: Thread?

    init() throws {
        #if canImport(Darwin)
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            throw XCTSkip("no pseudo-terminal available")
        }
        slavePath = String(cString: name)
        #else
        // Swift's Glibc module doesn't expose posix_openpt/grantpt/ptsname, so
        // do what they do: open the multiplexer, unlock, ask for the number.
        master = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        var unlock: Int32 = 0
        var number: UInt32 = 0
        guard master >= 0,
              ioctl(master, 0x4004_5431 /* TIOCSPTLCK */, &unlock) == 0,
              ioctl(master, 0x8004_5430 /* TIOCGPTN */, &number) == 0 else {
            throw XCTSkip("no pseudo-terminal available")
        }
        slavePath = "/dev/pts/\(number)"
        #endif
    }

    func start() {
        let t = Thread { [self] in run() }
        thread = t
        t.start()
    }

    var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func emit(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        let step = chunkSize > 0 ? chunkSize : max(bytes.count, 1)
        while offset < bytes.count {
            let end = min(offset + step, bytes.count)
            var sent = offset
            while sent < end {
                let n = bytes[sent..<end].withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
                if n <= 0 { return }
                sent += n
            }
            offset = end
            if chunkSize > 0 { usleep(2_000) }
        }
    }

    /// Simulates pulling the USB adapter.
    func unplug() {
        lock.lock(); stopped = true; lock.unlock()
        close(master)
    }

    private func run() {
        var line: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { return }
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 20) > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if n <= 0 { usleep(5_000); continue }
            for byte in buffer[..<n] {
                if byte == 0x0A || byte == 0x0D {
                    handle(String(decoding: line, as: UTF8.self))
                    line.removeAll()
                } else {
                    line.append(byte)
                }
            }
        }
    }

    private func handle(_ command: String) {
        lock.lock(); received.append(command); lock.unlock()
        if echo { emit(command + "\r\n") }
        if command.isEmpty { emit(Self.prompt); return }
        guard let entry = replies[command] else {
            emit("\u{1B}[0;31mERROR: unknown command '\(command)'\u{1B}[0m\r\nExit code = 0x80000001\r\n" + Self.prompt)
            return
        }
        guard let reply = entry else { return }  // hang
        emit(reply + Self.prompt)
    }
}

final class DiagsSerialTests: XCTestCase {

    // MARK: Pure parsing

    func testStripANSI() {
        XCTAssertEqual(DiagsSerialSession.stripANSI("\u{1B}[0;31mERROR: bad\u{1B}[0m"), "ERROR: bad")
        XCTAssertEqual(DiagsSerialSession.stripANSI("a\u{1B}[0;35mwarn\u{1B}[0mb"), "awarnb")
        XCTAssertEqual(DiagsSerialSession.stripANSI("\u{1B}[2J\u{1B}[1;1Hhome\u{1B}[K"), "home")
        XCTAssertEqual(DiagsSerialSession.stripANSI("\u{1B}]0;title\u{07}text"), "text")
        XCTAssertEqual(DiagsSerialSession.stripANSI("plain [0;31m not an escape"), "plain [0;31m not an escape")
        XCTAssertEqual(DiagsSerialSession.stripANSI("cut short \u{1B}[0;3"), "cut short ")
        XCTAssertEqual(DiagsSerialSession.stripANSI("cut \u{1B}[0;3\nnext"), "cut \nnext", "a newline inside a broken escape survives")
        XCTAssertEqual(DiagsSerialSession.stripANSI("end\u{1B}"), "end")
        XCTAssertEqual(DiagsSerialSession.stripANSI("caf\u{E9} ✓"), "caf\u{E9} ✓")
    }

    func testCleanOutputRemovesEchoAndPrompt() {
        let raw = "sysinfo\r\n\u{1B}[0;35mWARNING: x\u{1B}[0m\r\nBoard: b238aap   \r\n\r\nExit code = 0x00000000\r\n[00092951386A6F26] :-) "
        XCTAssertEqual(DiagsSerialSession.cleanOutput(raw, command: "sysinfo"),
                       "WARNING: x\nBoard: b238aap\n\nExit code = 0x00000000")
        // Prompt redrawn in front of the echo.
        XCTAssertEqual(DiagsSerialSession.cleanOutput("[AB] :-) sn\r\nCC4VKKTQHQK8\r\n[AB] :-) ", command: "sn"), "CC4VKKTQHQK8")
        // No echo at all: the first line is output and must be kept.
        XCTAssertEqual(DiagsSerialSession.cleanOutput("CC4VKKTQHQK8\r\n[AB] :-) ", command: "sn"), "CC4VKKTQHQK8")
        // Output whose first line merely starts with the command word is kept.
        XCTAssertEqual(DiagsSerialSession.cleanOutput("sn: not set\r\n[AB] :-) ", command: "sn"), "sn: not set")
        XCTAssertEqual(DiagsSerialSession.cleanOutput("version\r\n[AB] :-) ", command: "version"), "")
    }

    func testResultFields() {
        let ok = DiagsSerialSession.result(command: "version", rawOutput: "version\r\nDiags 1.2\r\nExit code = 0x00000000\r\n[AB] :-) ")
        XCTAssertEqual(ok.exitCode, "0x00000000")
        XCTAssertEqual(ok.exitCodeValue, 0)
        XCTAssertFalse(ok.hasError)
        XCTAssertTrue(ok.succeeded)
        XCTAssertTrue(ok.rawOutput.contains(":-)"))

        let bad = DiagsSerialSession.result(command: "x", rawOutput: "x\r\n\u{1B}[0;31mERROR: nope\u{1B}[0m\r\nExit code = 0x8000000E\r\n[AB] :-) ")
        XCTAssertTrue(bad.hasError)
        XCTAssertEqual(bad.exitCode, "0x8000000E")
        XCTAssertFalse(bad.succeeded)

        let quiet = DiagsSerialSession.result(command: "sn", rawOutput: "sn\r\nCC4VKKTQHQK8\r\n[AB] :-) ")
        XCTAssertNil(quiet.exitCode)
        XCTAssertTrue(quiet.succeeded)

        // "ERROR:" only counts at the start of a line.
        XCTAssertFalse(DiagsSerialSession.containsErrorLine("no ERROR: here"))
        XCTAssertTrue(DiagsSerialSession.containsErrorLine("fine\n  ERROR: indented"))
        // Non-zero exit code alone is a failure even without an ERROR line.
        XCTAssertFalse(DiagsSerialSession.result(command: "y", rawOutput: "y\r\nExit code = 0x00000001\r\n[AB] :-) ").succeeded)
    }

    func testPromptAndECID() throws {
        let found = try XCTUnwrap(DiagsSerialSession.prompt(in: "boot log\r\n\u{1B}[0m[00092951386a6f26] :-) "))
        XCTAssertEqual(found.line, "[00092951386a6f26] :-)")
        XCTAssertEqual(found.ecid, "00092951386A6F26")
        XCTAssertNil(DiagsSerialSession.prompt(in: "no prompt here"))
        XCTAssertNil(try XCTUnwrap(DiagsSerialSession.prompt(in: ":-) ")).ecid)
    }

    func testParseSysCfgList() {
        let text = """
        Key: SrNm = CC4VKKTQHQK8
        Key: MLB# = CC4741500NYJK2N1K
        Key: Regn = LL/A
        Key: CFG# = 0
        Key: WMac = 0xE37A81D0 0x00009476 0x00000000 0x00000000
        Key: MdlC = 0;MoPED=0x617B20F1D1A2D12A22D16A82251C581194B75F07
        Key: WCAL = 0x00000001 0x00000002
        0x00000003 0x00000004
        some unrelated line = with an equals sign
        Exit code = 0x00000000
        """
        let entries = DiagsSerialSession.parseSysCfgList(text)
        XCTAssertEqual(entries.map(\.key), ["SrNm", "MLB#", "Regn", "CFG#", "WMac", "MdlC", "WCAL"])
        XCTAssertEqual(entries[0].value, "CC4VKKTQHQK8")
        XCTAssertEqual(entries[0].meaning, "Serial number")
        XCTAssertFalse(entries[0].isBinary)
        XCTAssertEqual(entries[3].value, "0")
        XCTAssertEqual(entries[4].words, [0xE37A81D0, 0x00009476, 0, 0])
        XCTAssertEqual(entries[5].value, "0;MoPED=0x617B20F1D1A2D12A22D16A82251C581194B75F07", "only the first = splits")
        XCTAssertEqual(entries[6].words, [1, 2, 3, 4], "continuation lines of hex words join the entry")

        // Bare `XXXX = value` lines are accepted; a repeated key keeps the last value.
        let bare = DiagsSerialSession.parseSysCfgList("SrNm = A\nSrNm = B\nBMac = 0x1")
        XCTAssertEqual(bare, [SysCfgEntry(key: "SrNm", value: "B"), SysCfgEntry(key: "BMac", value: "0x1")])
        XCTAssertTrue(DiagsSerialSession.parseSysCfgList("ERROR: no syscfg\nExit code = 0x1").isEmpty)
    }

    func testValueFromPrint() {
        XCTAssertEqual(DiagsSerialSession.valueFromPrint("Key: SrNm = CC4VKKTQHQK8", key: "SrNm"), "CC4VKKTQHQK8")
        XCTAssertEqual(DiagsSerialSession.valueFromPrint("CC4VKKTQHQK8\nExit code = 0x00000000", key: "SrNm"), "CC4VKKTQHQK8")
    }

    func testValidation() {
        XCTAssertEqual(try DiagsSerialSession.validatedCommand("  syscfg list "), "syscfg list")
        XCTAssertThrowsError(try DiagsSerialSession.validatedCommand(""))
        XCTAssertThrowsError(try DiagsSerialSession.validatedCommand("sn\nsyscfg init"), "a second line would be a second command")
        XCTAssertThrowsError(try DiagsSerialSession.validatedCommand("sn\rsyscfg init"))
        XCTAssertThrowsError(try DiagsSerialSession.validatedCommand("sn\u{1B}[A"))
        XCTAssertTrue(DiagsSerialSession.isSysCfgKey("MLB#"))
        XCTAssertFalse(DiagsSerialSession.isSysCfgKey("SrN"))
        XCTAssertFalse(DiagsSerialSession.isSysCfgKey("Sr Nm"))
        XCTAssertFalse(DiagsSerialSession.isSysCfgKey("Sr m"))
        XCTAssertThrowsError(try DiagsSerialSession.validatedValue("  "))
        XCTAssertThrowsError(try DiagsSerialSession.validatedValue("ABC\nsyscfg init"))
        XCTAssertEqual(try DiagsSerialSession.validatedValue(" 0x1 0x2 "), "0x1 0x2")
    }

    func testQuickActionsMatchTheReference() {
        for kind in DiagsQuickAction.Kind.allCases {
            XCTAssertEqual(DiagsQuickAction.all.filter { $0.kind == kind }.count, 1, kind.rawValue)
        }
        for action in DiagsQuickAction.all {
            XCTAssertFalse(action.commands.isEmpty, action.title)
            for line in action.commands {
                XCTAssertNotNil(DiagsCommandReference.command(forLine: line), "\(line) isn't in the reference")
                XCTAssertNoThrow(try DiagsSerialSession.validatedCommand(line))
            }
            // No button may write flash: writes only go through the SysCfg form.
            XCTAssertNotEqual(action.risk, .writesFlash, action.title)
            // No button may send a command known to panic the pod.
            XCTAssertNotEqual(action.risk, .crashesDevice, action.title)
            for line in action.commands {
                XCTAssertNotEqual(DiagsCommandReference.risk(ofLine: line), .crashesDevice, line)
                XCTAssertFalse(line.lowercased().contains("nandinfotool"), "NANDInfoTool panics the pod")
                // Bare forms that only print a usage error on a real unit.
                XCTAssertFalse(["nand", "temperature", "sensor", "wifi", "bluetooth", "playaudio", "recordaudio"].contains(line),
                               "bare `\(line)` only prints a usage error")
            }
        }
        XCTAssertEqual(DiagsQuickAction.action(.nandHealth).commands, ["nandcsid", "nandppnfwver", "nanduid", "blockdevice"])
        XCTAssertEqual(DiagsQuickAction.action(.nandHealth).risk, .readOnly)
        XCTAssertEqual(DiagsQuickAction.action(.sensors).commands,
                       ["pmutemp", "temperature --all", "sensor -s touch --get temp", "pmustat all"])
        XCTAssertEqual(DiagsQuickAction.action(.audioInit).risk, .changesState, "`ampcontroller --init` changes live state")
        XCTAssertEqual(DiagsQuickAction.action(.audioInfo).risk, .readOnly, "`playaudio --listcaps` only prints")
        XCTAssertEqual(DiagsQuickAction.action(.wifi).commands, ["wifi --list", "wifi --get", "wifi --properties"])
        XCTAssertEqual(DiagsQuickAction.action(.bluetooth).commands, ["bluetooth --list", "bluetooth --properties"])
        XCTAssertEqual(DiagsQuickAction.action(.readSerial).risk, .readOnly, "bare `sn` only reads")
        XCTAssertEqual(DiagsQuickAction.action(.sysCfgList).risk, .readOnly)
        XCTAssertEqual(DiagsQuickAction.action(.ledOn).risk, .changesState)
        XCTAssertEqual(DiagsQuickAction.action(.systemInfo).commands, ["sysinfo", "version", "boardid", "boardrev", "chipid"])
        XCTAssertTrue(DiagsQuickAction.action(.sensors).help.contains("temperature"))
        XCTAssertEqual(DiagsQuickAction.categories,
                       [.deviceInfo, .factoryHistory, .sysCfg, .nand, .storage, .memory, .audio, .sensor, .power, .radio, .led])
    }

    func testNewQuickActions() {
        func commands(_ kind: DiagsQuickAction.Kind) -> [String] { DiagsQuickAction.action(kind).commands }
        XCTAssertEqual(commands(.system), ["system"])
        XCTAssertEqual(commands(.socInfo), ["soc"])
        XCTAssertEqual(commands(.bootConfig), ["bootcfg"])
        XCTAssertEqual(commands(.controlBits), ["cbreadall"])
        XCTAssertEqual(commands(.controlBitDump), ["cbdump"])
        XCTAssertEqual(commands(.pmuEvents), ["pmuevent all"])
        XCTAssertEqual(commands(.pmuADC), ["help pmuadc"], "the ADC's arguments aren't known: ask, don't guess")
        XCTAssertEqual(commands(.pmuRegisters), ["pmureg"])
        XCTAssertEqual(commands(.buckCheck), ["buckcheck"])
        XCTAssertEqual(commands(.rtc), ["rtc --get"])
        XCTAssertEqual(commands(.nandTests), ["nand --testlist"])
        XCTAssertEqual(commands(.nandParams), ["nand --getinfo"])
        XCTAssertEqual(commands(.memoryInfo), ["memory --info", "memory --list"])
        XCTAssertEqual(commands(.memoryMap), ["dumpmemmap"])
        XCTAssertEqual(commands(.filesystem), ["dir fs0:", "dir nandfs:"])
        XCTAssertEqual(commands(.nvram), ["nvram -p"])
        XCTAssertEqual(commands(.ledRed), ["strobe -c led -s All_RGB --set red 25"])
        XCTAssertEqual(commands(.ledGreen), ["strobe -c led -s All_RGB --set green 25"])
        XCTAssertEqual(commands(.ledBlue), ["strobe -c led -s All_RGB --set blue 25"])
        XCTAssertEqual(commands(.ledWhite), ["strobe -c led -s All_RGB --set red 25",
                                             "strobe -c led -s All_RGB --set green 25",
                                             "strobe -c led -s All_RGB --set blue 25"])

        // Everything new only reads, except the LED colours (live state).
        let ledColours: [DiagsQuickAction.Kind] = [.ledRed, .ledGreen, .ledBlue, .ledWhite]
        let readOnly: [DiagsQuickAction.Kind] = [.system, .socInfo, .bootConfig, .controlBits, .controlBitDump,
                                                 .pmuEvents, .pmuADC, .pmuRegisters, .buckCheck, .rtc,
                                                 .nandTests, .nandParams, .memoryInfo, .memoryMap, .filesystem, .nvram]
        for kind in readOnly { XCTAssertEqual(DiagsQuickAction.action(kind).risk, .readOnly, kind.rawValue) }
        for kind in ledColours { XCTAssertEqual(DiagsQuickAction.action(kind).risk, .changesState, kind.rawValue) }

        XCTAssertEqual(DiagsQuickAction.actions(in: .factoryHistory).map(\.kind), [.controlBits, .controlBitDump])
        XCTAssertEqual(DiagsQuickAction.actions(in: .power).map(\.kind), [.pmuEvents, .pmuADC, .pmuRegisters, .buckCheck, .rtc])
        XCTAssertEqual(DiagsQuickAction.actions(in: .memory).map(\.kind), [.memoryInfo, .memoryMap])
        XCTAssertEqual(DiagsQuickAction.actions(in: .storage).map(\.kind), [.filesystem, .nvram])
        XCTAssertEqual(DiagsQuickAction.actions(in: .led).map(\.kind), [.ledOn, .ledOff, .ledRed, .ledGreen, .ledBlue, .ledWhite])
        XCTAssertEqual(DiagsQuickAction.actions(in: .deviceInfo).map(\.kind), [.systemInfo, .system, .socInfo, .bootConfig])
        XCTAssertTrue(DiagsQuickAction.action(.controlBits).isSlow, "256 stations of output")
        XCTAssertTrue(DiagsQuickAction.action(.nvram).help.contains("help nvram"))

        // Confirmed on real hardware.
        for name in ["cbreadall", "strobe", "system", "device"] {
            XCTAssertEqual(DiagsCommandReference.command(named: name)?.source, .benchTested, name)
        }
    }

    // MARK: Model reconfiguration (colour swap)

    func testModelVariants() {
        XCTAssertEqual(HomePodModelVariant.variant(for: "MQHW2"), .spaceGray)
        XCTAssertEqual(HomePodModelVariant.variant(for: "MQHV2LL/A"), .white)
        XCTAssertEqual(HomePodModelVariant.variant(for: " mqhw2x/a "), .spaceGray)
        XCTAssertNil(HomePodModelVariant.variant(for: "MQJ83"))
        XCTAssertNil(HomePodModelVariant.variant(for: ""))

        XCTAssertEqual(HomePodModelVariant.remodel("MQHW2", to: .white), "MQHV2")
        XCTAssertEqual(HomePodModelVariant.remodel("MQHV2", to: .spaceGray), "MQHW2")
        XCTAssertEqual(HomePodModelVariant.remodel("MQHW2LL/A", to: .white), "MQHV2LL/A", "the region suffix is kept")
        XCTAssertEqual(HomePodModelVariant.remodel("MQHW2X/A", to: .white), "MQHV2X/A")
        XCTAssertEqual(HomePodModelVariant.remodel("MQHW2", to: .spaceGray), "MQHW2")
        XCTAssertEqual(HomePodModelVariant.remodel("ZZZZ9", to: .white), "MQHV2", "an unknown model gives the bare target")
        XCTAssertEqual(HomePodModelVariant.remodel("", to: .spaceGray), "MQHW2")
        XCTAssertEqual(HomePodModelVariant.all.map(\.color), ["Space Gray", "White"])
    }

    func testModelValidationAndCommands() throws {
        XCTAssertEqual(try DiagsSerialSession.validatedModelNumber(" MQHV2 "), "MQHV2")
        XCTAssertEqual(try DiagsSerialSession.validatedModelNumber("MQHV2LL/A"), "MQHV2LL/A")
        for bad in ["", "MQ", "MQHV2 LL/A", "MQHV2\nsyscfg init", "MQHV2;sn", "MQHV2LL/AMQHV2LL/A"] {
            XCTAssertThrowsError(try DiagsSerialSession.validatedModelNumber(bad), bad) { error in
                guard case .invalidModel = error as? DiagsSerialError else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try DiagsSerialSession.modelReconfigureCommands(to: bad), bad)
        }
        let commands = try DiagsSerialSession.modelReconfigureCommands(to: "MQHV2")
        XCTAssertEqual(commands, ["syscfg delete Mod#", "syscfg add Mod# MQHV2", "syscfg print Mod#"])
        XCTAssertEqual(commands.map { DiagsCommandReference.risk(ofLine: $0) }, [.writesFlash, .writesFlash, .readOnly])
        for line in commands { XCTAssertNoThrow(try DiagsSerialSession.validatedCommand(line)) }
        XCTAssertTrue(DiagsSerialSession.isSysCfgKey(DiagsSerialSession.modelKey))
    }

    func testReconfigureModel() throws {
        let shell = try FakeDiagsShell()
        shell.replies["syscfg delete Mod#"] = "Exit code = 0x00000000\r\n"
        shell.replies["syscfg add Mod# MQHV2"] = "Exit code = 0x00000000\r\n"
        shell.replies["syscfg print Mod#"] = "Key: Mod# = MQHV2\r\nExit code = 0x00000000\r\n"
        shell.replies["syscfg add Mod# MQHW2"] = "Exit code = 0x00000000\r\n"
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }

        XCTAssertEqual(try session.reconfigureModel(to: " MQHV2 "), "MQHV2")
        XCTAssertEqual(shell.commands, ["syscfg delete Mod#", "syscfg add Mod# MQHV2", "syscfg print Mod#"])

        // A model that isn't valid sends nothing at all — above all, no delete.
        XCTAssertThrowsError(try session.reconfigureModel(to: "MQHV2 LL/A"))
        XCTAssertEqual(shell.commands.count, 3)

        // The read-back is the proof: the fake still answers MQHV2.
        XCTAssertThrowsError(try session.reconfigureModel(to: "MQHW2")) { error in
            XCTAssertEqual(error as? DiagsSerialError, .modelNotVerified(expected: "MQHW2", found: "MQHV2"))
        }
    }

    func testVerifiedModel() throws {
        func result(_ command: String, _ output: String) -> DiagsCommandResult {
            DiagsSerialSession.result(command: command, rawOutput: command + "\r\n" + output + "\r\n[AB] :-) ")
        }
        let delete = result("syscfg delete Mod#", "ERROR: key not found")   // never set: allowed to complain
        let add = result("syscfg add Mod# MQHW2", "")
        XCTAssertEqual(try DiagsSerialSession.verifiedModel(from: [delete, add, result("syscfg print Mod#", "MQHW2")], expected: "MQHW2"), "MQHW2")
        XCTAssertThrowsError(try DiagsSerialSession.verifiedModel(from: [delete, add, result("syscfg print Mod#", "ERROR: not found")], expected: "MQHW2")) { error in
            XCTAssertEqual(error as? DiagsSerialError, .modelNotVerified(expected: "MQHW2", found: ""))
        }
        XCTAssertThrowsError(try DiagsSerialSession.verifiedModel(from: [delete, add], expected: "MQHW2"))
    }


    func testPortHelpers() throws {
        XCTAssertTrue(SerialPort.lastLine(of: Array("a\nb :-) ".utf8), contains: Array(":-)".utf8)))
        XCTAssertFalse(SerialPort.lastLine(of: Array("smile :-)\nmore".utf8), contains: Array(":-)".utf8)))
        XCTAssertFalse(SerialPort.lastLine(of: Array(":-".utf8), contains: Array(":-)".utf8)))
        XCTAssertEqual(SerialPort.utf8SafePrefixLength(Array("ab".utf8)), 2)
        XCTAssertEqual(SerialPort.utf8SafePrefixLength([0x61, 0xE2, 0x9C]), 1, "half of a ✓ waits for the rest")
        XCTAssertEqual(SerialPort.utf8SafePrefixLength([0x61, 0xE2, 0x9C, 0x93]), 4)
        XCTAssertEqual(SerialPort.utf8SafePrefixLength([]), 0)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["cu.Bluetooth-Incoming-Port", "cu.usbserial-A10", "cu.usbserial-A2", "cu.SLAB_USBtoUART", "tty.usbserial-A2", "null"] {
            _ = FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        }
        XCTAssertEqual(SerialPort.availablePorts(in: dir.path).map { ($0 as NSString).lastPathComponent },
                       ["cu.SLAB_USBtoUART", "cu.usbserial-A2", "cu.usbserial-A10", "cu.Bluetooth-Incoming-Port"])
        XCTAssertTrue(SerialPort.availablePorts(in: "/nonexistent-dir").isEmpty)
    }

    func testOpenFailures() throws {
        let missing = SerialPort(path: "/dev/cu.definitely-not-here")
        XCTAssertThrowsError(try missing.open()) { error in
            XCTAssertEqual(error as? SerialPortError, .openFailed(path: "/dev/cu.definitely-not-here", code: ENOENT))
            XCTAssertTrue(error.localizedDescription.contains("plugged in"))
        }
        XCTAssertFalse(missing.isOpen)
        XCTAssertThrowsError(try missing.send("x")) { XCTAssertEqual($0 as? SerialPortError, .notOpen) }
        XCTAssertThrowsError(try missing.readLine(timeout: 0.05)) { XCTAssertEqual($0 as? SerialPortError, .notOpen) }
        missing.close()  // harmless

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notaport-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try SerialPort(path: file.path).open()) { error in
            guard case .notASerialDevice = error as? SerialPortError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try SerialPort(path: "/dev/null", baudRate: -5).open())
    }

    // MARK: Against the fake shell (real termios + poll on a pty)

    private func connect(_ shell: FakeDiagsShell) throws -> DiagsSerialSession {
        let port = SerialPort(path: shell.slavePath)
        try port.open()
        shell.start()
        return DiagsSerialSession(port: port)
    }

    func testPromptCommandAndECID() throws {
        let shell = try FakeDiagsShell()
        shell.replies["sn"] = "Serial: CC4VKKTQHQK8\r\nExit code = 0x00000000\r\n"
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }

        XCTAssertTrue(session.port.isOpen)
        XCTAssertThrowsError(try session.port.open()) { XCTAssertEqual($0 as? SerialPortError, .alreadyOpen) }
        XCTAssertEqual(try session.waitForPrompt(), "[\(FakeDiagsShell.ecid)] :-)")
        XCTAssertEqual(session.ecid, FakeDiagsShell.ecid)

        let result = try session.runCommand("sn")
        XCTAssertEqual(result.command, "sn")
        XCTAssertEqual(result.cleanOutput, "Serial: CC4VKKTQHQK8\nExit code = 0x00000000")
        XCTAssertEqual(result.exitCode, "0x00000000")
        XCTAssertFalse(result.hasError)
        XCTAssertTrue(result.rawOutput.hasPrefix("sn\r\n"))
        XCTAssertEqual(shell.commands, ["", "sn"])

        let unknown = try session.runCommand("frobnicate")
        XCTAssertTrue(unknown.hasError)
        XCTAssertEqual(unknown.cleanOutput, "ERROR: unknown command 'frobnicate'\nExit code = 0x80000001")
        XCTAssertFalse(unknown.rawOutput == unknown.cleanOutput, "raw keeps the colour codes")
    }

    func testWorksWithoutEcho() throws {
        let shell = try FakeDiagsShell()
        shell.echo = false
        shell.replies["version"] = "version 1.0\r\n"
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }
        XCTAssertEqual(try session.runCommand("version").cleanOutput, "version 1.0")
    }

    func testLargeOutputInSmallPieces() throws {
        let shell = try FakeDiagsShell()
        // ~150 KB of hex words dribbled out 512 bytes at a time: the idle
        // timeout (0.5 s here) must keep being pushed back while data flows.
        let blob = (0..<13_000).map { String(format: "0x%08X", $0) }.joined(separator: " ")
        shell.replies["syscfg list"] = "Key: SrNm = CC4VKKTQHQK8\r\nKey: WCAL = \(blob)\r\nKey: Regn = LL/A\r\n"
        shell.chunkSize = 512
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }
        session.longCommandTimeout = 0.5

        let entries = try session.syscfgList()
        XCTAssertEqual(entries.map(\.key), ["SrNm", "WCAL", "Regn"])
        XCTAssertEqual(entries[1].words?.count, 13_000)
        XCTAssertEqual(entries[1].words?.last, 12_999)
        XCTAssertEqual(try session.syscfgPrint("Regn"), "ERROR: unknown command 'syscfg print Regn'")
        XCTAssertThrowsError(try session.syscfgPrint("toolong")) { XCTAssertEqual($0 as? DiagsSerialError, .invalidKey("toolong")) }
    }

    func testStalePromptIsNotMistakenForTheAnswer() throws {
        let shell = try FakeDiagsShell()
        shell.replies["boardid"] = "0x38\r\n"
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }
        // Unsolicited output (with a prompt in it) arrives before the command.
        shell.emit("late boot message\r\n" + FakeDiagsShell.prompt)
        usleep(100_000)
        XCTAssertEqual(try session.runCommand("boardid").cleanOutput, "0x38")
    }

    func testUnsolicitedOutput() throws {
        let shell = try FakeDiagsShell()
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }
        XCTAssertEqual(try session.readUnsolicited(), "")
        shell.emit("\u{1B}[0;35miBoot says hi\u{1B}[0m\r\n" + FakeDiagsShell.prompt)
        usleep(100_000)
        XCTAssertEqual(try session.readUnsolicited(), "iBoot says hi\n[\(FakeDiagsShell.ecid)] :-) ")
        XCTAssertEqual(session.ecid, FakeDiagsShell.ecid, "the ECID is picked up from a prompt seen while idle")
    }

    func testTimeoutCarriesPartialOutput() throws {
        let shell = try FakeDiagsShell()
        shell.replies["playaudio"] = .some(nil)  // echoes, then never answers
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }

        let started = Date()
        XCTAssertThrowsError(try session.runCommand("playaudio", timeout: 0.3)) { error in
            XCTAssertEqual(error as? DiagsSerialError, .commandTimedOut(command: "playaudio", partial: ""))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        // The port is still usable afterwards.
        XCTAssertEqual(try session.waitForPrompt(), "[\(FakeDiagsShell.ecid)] :-)")
    }

    func testNoPrompt() throws {
        let shell = try FakeDiagsShell()
        let port = SerialPort(path: shell.slavePath)
        try port.open()  // nobody is listening on the other side
        defer { port.close(); shell.unplug() }
        XCTAssertThrowsError(try DiagsSerialSession(port: port).waitForPrompt(timeout: 0.2)) { error in
            guard case .noPrompt = error as? DiagsSerialError else { return XCTFail("\(error)") }
        }
    }

    func testReadLine() throws {
        let shell = try FakeDiagsShell()
        let port = SerialPort(path: shell.slavePath)
        try port.open()
        defer { port.close(); shell.unplug() }
        shell.emit("one\r\ntwo\nthr")
        XCTAssertEqual(try port.readLine(timeout: 1), "one")
        XCTAssertEqual(try port.readLine(timeout: 1), "two")
        XCTAssertNil(try port.readLine(timeout: 0.1), "an unterminated line isn't a line yet")
        shell.emit("ee\r\n")
        XCTAssertEqual(try port.readLine(timeout: 1), "three", "…and nothing of it was lost")
        // sendAndCollect with a custom marker.
        port.lineTerminator = "\r"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { shell.emit("ok\r\nDONE> ") }
        XCTAssertEqual(try port.sendAndCollect("go", until: "DONE>", timeout: 2), "ok\r\nDONE> ")
    }

    func testUnplugIsReportedAsDisconnect() throws {
        let shell = try FakeDiagsShell()
        shell.replies["temperature"] = .some(nil)
        let session = try connect(shell)
        defer { session.port.close() }
        _ = try session.waitForPrompt()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { shell.unplug() }
        let started = Date()
        XCTAssertThrowsError(try session.runCommand("temperature", timeout: 5)) { error in
            XCTAssertEqual(error as? SerialPortError, .disconnected)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "noticed long before the timeout")
        XCTAssertThrowsError(try session.readUnsolicited()) { XCTAssertEqual($0 as? SerialPortError, .disconnected) }
    }

    func testCloseInterruptsABlockedRead() throws {
        let shell = try FakeDiagsShell()
        shell.replies["recordaudio"] = .some(nil)
        let session = try connect(shell)
        defer { shell.unplug() }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { session.port.close() }
        let started = Date()
        XCTAssertThrowsError(try session.runCommand("recordaudio", timeout: 10)) { error in
            XCTAssertEqual(error as? SerialPortError, .notOpen)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(session.port.isOpen)
        session.port.close()  // twice is fine

        // And it can be reopened.
        try session.port.open()
        XCTAssertTrue(session.port.isOpen)
        session.port.close()
    }

    func testCancelStopsWaitingButKeepsThePortOpen() throws {
        let shell = try FakeDiagsShell()
        shell.replies["playaudio"] = .some(nil)
        shell.replies["version"] = "Diags 1.0\r\n"
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }

        session.cancelCurrentCommand()  // a stale cancel must not hit the next command
        XCTAssertEqual(try session.runCommand("version").cleanOutput, "Diags 1.0")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { session.cancelCurrentCommand() }
        let started = Date()
        XCTAssertThrowsError(try session.runCommand("playaudio", timeout: 10)) { error in
            XCTAssertEqual(error as? DiagsSerialError, .commandCancelled(command: "playaudio", partial: ""))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(session.port.isOpen)
        XCTAssertEqual(try session.runCommand("version").cleanOutput, "Diags 1.0")
    }

    func testGroupedReadings() throws {
        let shell = try FakeDiagsShell()
        shell.replies["sysinfo"] = "Board: b238aap\r\n"
        shell.replies["version"] = "Diags 1.0\r\n"
        shell.replies["boardid"] = "0x38\r\n"
        shell.replies["boardrev"] = "0x5\r\n"
        shell.replies["chipid"] = ""
        let session = try connect(shell)
        defer { session.port.close(); shell.unplug() }

        XCTAssertEqual(try session.readSystemInfo(),
                       "> sysinfo\nBoard: b238aap\n\n> version\nDiags 1.0\n\n> boardid\n0x38\n\n> boardrev\n0x5\n\n> chipid")
        // A command that errors doesn't stop the ones after it.
        let nand = try session.readNANDInfo()
        XCTAssertTrue(nand.hasPrefix("> nandcsid\nERROR: unknown command 'nandcsid'"))
        XCTAssertTrue(nand.contains("> nanduid"))
        XCTAssertEqual(shell.commands, ["sysinfo", "version", "boardid", "boardrev", "chipid", "nandcsid", "nandppnfwver", "nanduid", "blockdevice"])
    }
}
