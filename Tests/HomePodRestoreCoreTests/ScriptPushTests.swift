import XCTest
@testable import HomePodRestoreCore

/// The diagnostic-script push: no base64 on the pod, a push directory chosen
/// at run time, a size check and one retry. No hardware.
final class ScriptPushTests: XCTestCase {

    /// What the pod's `printf '<format>'` would print: literal bytes plus
    /// three-digit octal escapes. Anything else in a format is a test failure.
    static func decodePrintfFormat(_ format: String) -> Data? {
        var out = Data()
        let bytes = Array(format.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") {
                guard i + 3 < bytes.count,
                      let text = String(bytes: bytes[(i + 1)...(i + 3)], encoding: .ascii),
                      let value = UInt8(text, radix: 8) else { return nil }
                out.append(value)
                i += 4
            } else {
                if bytes[i] == UInt8(ascii: "%") || bytes[i] == UInt8(ascii: "'") || bytes[i] < 0x20 { return nil }
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    /// The format inside the first `printf '…'` of a command.
    static func printfFormat(in command: String) -> String? {
        guard let start = command.range(of: "printf '") else { return nil }
        let rest = command[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    func testPrintfChunksRoundTripEveryByte() {
        var data = Data()
        for _ in 0..<3 { data.append(contentsOf: (0...255).map { UInt8($0) }) }
        data.append(Data("-v x\n--\n%s 'q' `x` \\n\t".utf8))
        for budget in [8, 9, 97, DiagCommands.transferBudget] {
            let chunks = DiagCommands.printfChunks(for: data, budget: budget)
            var back = Data()
            for chunk in chunks {
                XCTAssertLessThanOrEqual(chunk.utf8.count, budget)
                XCTAssertFalse(chunk.hasPrefix("-"), "a format starting with - would be read as an option")
                guard let decoded = Self.decodePrintfFormat(chunk) else { return XCTFail("unsafe format: \(chunk.prefix(40))") }
                back.append(decoded)
            }
            XCTAssertEqual(back, data, "budget \(budget)")
        }
        XCTAssertTrue(DiagCommands.printfChunks(for: Data()).isEmpty)
    }

    func testPushCommandsNeedNoDecoderOnThePod() {
        let script = DiagScript(name: "hpdiag-nand", text: "#!/bin/sh\necho '100%' \"$1\"\n")
        let commands = DiagCommands.scriptPushCommands(name: script.name, content: script.content,
                                                       directory: "/private/var/tmp/hpdiag")
        XCTAssertEqual(commands.count, 1)
        let command = commands[0]
        XCTAssertFalse(command.contains("base64"))
        XCTAssertFalse(command.contains("\n"))
        XCTAssertTrue(command.contains("mkdir -p /private/var/tmp/hpdiag"))
        XCTAssertTrue(command.contains("> /private/var/tmp/hpdiag/hpdiag-nand"))
        XCTAssertTrue(command.contains("chmod 755 /private/var/tmp/hpdiag/hpdiag-nand"))
        XCTAssertEqual(Self.printfFormat(in: command).flatMap(Self.decodePrintfFormat), script.content)

        // A small budget splits the script; the first command truncates, the
        // rest append, and only the last one reports the size.
        let split = DiagCommands.scriptPushCommands(name: script.name, content: script.content, budget: 16)
        XCTAssertGreaterThan(split.count, 1)
        XCTAssertTrue(split[0].contains("' > /private/var/tmp/hpdiag/hpdiag-nand"))
        XCTAssertTrue(split[1].contains("' >> /private/var/tmp/hpdiag/hpdiag-nand"))
        XCTAssertFalse(split[0].contains(DiagCommands.pushedMarkerPrefix))
        XCTAssertTrue(split[split.count - 1].contains(DiagCommands.pushedMarkerPrefix))
        var back = Data()
        for part in split { back.append(Self.printfFormat(in: part).flatMap(Self.decodePrintfFormat) ?? Data()) }
        XCTAssertEqual(back, script.content)
    }

    /// The SSH ramdisk's root has no /tmp (only /private/var/tmp and
    /// /private/var/root), so neither the script push nor blob staging may use it.
    func testNothingIsPushedOrStagedUnderTmp() {
        XCTAssertEqual(DiagCommands.pushDirectory, "/private/var/tmp/hpdiag")
        XCTAssertFalse(DiagCommands.pushDirectories.contains { $0.hasPrefix("/tmp") })
        XCTAssertFalse(DiagCommands.path.split(separator: ":").contains { $0.hasPrefix("/tmp") })
        XCTAssertFalse(DiagCommands.scriptCheck(names: ["hpdiag-nand"]).contains(" /tmp/"))
        XCTAssertFalse(EffaceableLockerSink.Settings().stagePath.hasPrefix("/tmp"))
        XCTAssertFalse(DiagsKextSink.Settings().stagePath.hasPrefix("/tmp"))
    }

    /// The tool check names only tools the scripts still call, all of which the
    /// ramdisk has; the ones it lacks were rewritten out of the scripts.
    func testScriptToolCheckListsNoToolTheRamdiskLacks() {
        for tool in ["awk", "tr", "sort", "od", "strings", "base64", "timeout"] {
            XCTAssertFalse(DiagCommands.scriptRequiredTools.contains(tool), tool)
        }
        XCTAssertTrue(DiagCommands.scriptCheck(names: ["hpdiag-nand"])
            .contains("for t in ioreg dd grep sed head cut wc hexdump expr; do"))
    }

    /// `dumpBinary` moves bytes as `xxd -p` hex (no base64 on the pod).
    func testHexDumpDecodesXxdOutput() {
        var data = Data((0...255).map { UInt8($0) })
        data.append(contentsOf: [0x00, 0xff, 0x0a])
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // xxd -p wraps every 60 hex digits; SSH output may carry CRs.
        var wrapped = ""
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 60, limitedBy: hex.endIndex) ?? hex.endIndex
            wrapped += String(hex[i..<j]) + "\r\n"
            i = j
        }
        XCTAssertEqual(SSHRamdiskTransport.decodeHexDump(wrapped), data)
        XCTAssertEqual(SSHRamdiskTransport.decodeHexDump("DEADbeef"), Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(SSHRamdiskTransport.decodeHexDump(""), Data())
        XCTAssertNil(SSHRamdiskTransport.decodeHexDump("abc"))        // odd number of digits
        XCTAssertNil(SSHRamdiskTransport.decodeHexDump("ab cd zz"))   // not hex
        XCTAssertNil(SSHRamdiskTransport.decodeHexDump("aGVsbG8="))   // base64 is not hex
    }

    func testFailureMessageTellsARemoteFailureFromADeadLink() {
        let dead = SSHRamdiskTransport.failureMessage(exitCode: 255, output: "ssh: connect to host 127.0.0.1 port 2222: Connection refused", port: 2222)
        XCTAssertTrue(dead.contains("port 2222 forwarded"))
        XCTAssertTrue(dead.contains("Connection refused"))
        let remote = SSHRamdiskTransport.failureMessage(exitCode: 1, output: "mkdir: /tmp: Read-only file system\n", port: 2222)
        XCTAssertTrue(remote.contains("exit 1"))
        XCTAssertTrue(remote.contains("Read-only file system"))
        XCTAssertFalse(remote.contains("forwarded"))
        XCTAssertTrue(SSHRamdiskTransport.failureMessage(exitCode: 127, output: "sh: base64: command not found", port: 2222).contains("base64: command not found"))
    }

    /// A pod with a file system: answers the check, applies pushes, keeps the stamp.
    final class FakePod: RamdiskShell, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Data] = [:]
        private var log: [String] = []
        private var failuresLeft: Int
        let directory: String
        let lacking: [String]

        init(directory: String, lacking: [String] = [], failFirstPushes: Int = 0) {
            self.directory = directory
            self.lacking = lacking
            self.failuresLeft = failFirstPushes
        }

        var files: [String: Data] { lock.lock(); defer { lock.unlock() }; return stored }
        var commands: [String] { lock.lock(); defer { lock.unlock() }; return log }

        func run(_ command: String) async throws -> String { try handle(command) }

        private func handle(_ command: String) throws -> String {
            lock.lock(); defer { lock.unlock() }
            log.append(command)
            if command.contains("pick()") {
                let stamp = stored["\(directory)/.stamp"].map { String(decoding: $0, as: UTF8.self) } ?? ""
                return (["HPDIAG_DIR \(directory)"] + lacking.map { "HPDIAG_LACK \($0)" } + ["HPDIAG_STAMP \(stamp)"])
                    .joined(separator: "\n") + "\n"
            }
            if command.hasPrefix("echo '") {
                let fingerprint = command.dropFirst("echo '".count).prefix { $0 != "'" }
                stored["\(directory)/.stamp"] = Data(fingerprint.utf8)
                return ""
            }
            guard let format = ScriptPushTests.printfFormat(in: command),
                  let bytes = ScriptPushTests.decodePrintfFormat(format),
                  let target = command.components(separatedBy: " ").first(where: { $0.hasPrefix("\(directory)/hpdiag-") }) else {
                throw SysCfgError.transportUnavailable("unexpected command")
            }
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw SysCfgError.transportUnavailable("SSH to the ramdisk failed (exit 255).")
            }
            stored["\(directory)/.stamp"] = Data()
            if command.contains("' >> ") { stored[target, default: Data()].append(bytes) } else { stored[target] = bytes }
            guard command.contains(DiagCommands.pushedMarkerPrefix) else { return "" }
            return "\(DiagCommands.pushedMarkerPrefix)     \(stored[target]?.count ?? 0)\n"
        }

        func dumpBinary(_ command: String) async throws -> Data { Data() }
    }

    static let scripts = [
        DiagScript(name: "hpdiag-accel", text: "#!/bin/sh\nexec hpdiag-sensors accel\n"),
        DiagScript(name: "hpdiag-nand", text: "#!/bin/sh\nawk 'BEGIN{printf \"%d\\n\", 1}'\n"),
    ]

    func testPushUsesTheDirectoryThePodReportsAndStampsIt() async {
        let pod = FakePod(directory: "/private/var/tmp/hpdiag", lacking: ["awk", "tr"])
        let lines = DiagParserTests.Collector<String>()
        let first = await FullDiagnosticsController.pushDiagnosticScripts(Self.scripts, via: pod) { lines.add($0) }
        XCTAssertEqual(first, .pushed(["hpdiag-accel", "hpdiag-nand"]))
        XCTAssertEqual(pod.files["/private/var/tmp/hpdiag/hpdiag-accel"], Self.scripts[0].content)
        XCTAssertEqual(pod.files["/private/var/tmp/hpdiag/hpdiag-nand"], Self.scripts[1].content)
        XCTAssertFalse(pod.commands.contains { $0.contains("base64") })
        XCTAssertTrue(lines.all.contains { $0.contains("no awk, tr") })
        XCTAssertTrue(DiagCommands.path.contains("/private/var/tmp/hpdiag:"))

        // Same scripts, same boot: one check, nothing copied again.
        let before = pod.commands.count
        let second = await FullDiagnosticsController.pushDiagnosticScripts(Self.scripts, via: pod)
        XCTAssertEqual(second, .alreadyPushed)
        XCTAssertEqual(pod.commands.count, before + 1)
    }

    func testPushRetriesAScriptOnce() async {
        let pod = FakePod(directory: "/private/var/root/hpdiag", failFirstPushes: 1)
        let result = await FullDiagnosticsController.pushDiagnosticScripts(Self.scripts, via: pod)
        XCTAssertEqual(result, .pushed(["hpdiag-accel", "hpdiag-nand"]))
        XCTAssertEqual(pod.files["/private/var/root/hpdiag/hpdiag-accel"], Self.scripts[0].content)
    }

    func testPushGivesUpAfterTwoFailuresAndSaysWhy() async {
        let pod = FakePod(directory: "/private/var/root/hpdiag", failFirstPushes: 2)
        let result = await FullDiagnosticsController.pushDiagnosticScripts(Self.scripts, via: pod)
        guard case .failed(let pushed, let message) = result else { return XCTFail("expected a failure") }
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertTrue(message.contains("hpdiag-accel"))
        XCTAssertTrue(message.contains("exit 255"))
    }

    func testPushFailsCleanlyWhenNothingIsWritable() async {
        let pod = FakePod(directory: "")
        let result = await FullDiagnosticsController.pushDiagnosticScripts(Self.scripts, via: pod)
        guard case .failed(_, let message) = result else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("writable"))
        XCTAssertEqual(pod.commands.count, 1)
    }
}
