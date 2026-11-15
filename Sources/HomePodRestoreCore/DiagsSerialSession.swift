import Foundation

// MARK: - DIAGS shell session over serial
//
// The factory DIAGS environment ("smokeyshell", see docs/diags-boot.md) is
// driven over UART. It prints a prompt of the form
//
//     [00092951386A6F26] :-)
//
// (the unit's ECID in hex, then `:-) ` with a trailing space) and takes
// plain-text commands ended by a newline. Its output is coloured with ANSI
// escapes (red for errors, purple for warnings), an error line starts with
// `ERROR:`, and a command's status shows up as `Exit code = 0xNNNNNNNN`.
//
// `DiagsSerialSession` wraps a `SerialPort` with that protocol: wait for the
// prompt, run a command and hand back its output with the echo, the colour
// codes and the closing prompt removed.
//
// Like `SerialPort`, everything here BLOCKS — call it from a background queue.
// Commands are serialised: two threads can't interleave their output.

/// The outcome of one DIAGS command.
public struct DiagsCommandResult: Sendable, Equatable {
    public let command: String
    /// Exactly what came back, echo, colour codes and prompt included.
    public let rawOutput: String
    /// ANSI stripped, echo and closing prompt removed.
    public let cleanOutput: String
    /// The value from an `Exit code = 0x…` line, if the command printed one.
    public let exitCode: String?
    /// A line of the output starts with `ERROR:`.
    public let hasError: Bool

    public init(command: String, rawOutput: String, cleanOutput: String, exitCode: String?, hasError: Bool) {
        self.command = command
        self.rawOutput = rawOutput
        self.cleanOutput = cleanOutput
        self.exitCode = exitCode
        self.hasError = hasError
    }

    /// `exitCode` as a number, when there is one.
    public var exitCodeValue: UInt64? {
        guard let exitCode else { return nil }
        let hex = exitCode.lowercased().hasPrefix("0x") ? String(exitCode.dropFirst(2)) : exitCode
        return UInt64(hex, radix: 16)
    }

    /// No `ERROR:` line and no non-zero exit code.
    public var succeeded: Bool { !hasError && (exitCodeValue ?? 0) == 0 }
}

/// One line of `syscfg list`: a four-character key and its printed value.
public struct SysCfgEntry: Sendable, Equatable, Identifiable {
    public let key: String
    /// The value as DIAGS printed it: text for string keys (`CC4VKKTQHQK8`),
    /// space-separated 32-bit hex words for binary keys (`0xE37A81D0 0x00009476 …`).
    public let value: String

    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// The value parsed as 32-bit words, when it is printed as hex words.
    public var words: [UInt32]? {
        let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !tokens.isEmpty else { return nil }
        var out: [UInt32] = []
        for token in tokens {
            guard token.lowercased().hasPrefix("0x"), let word = UInt32(token.dropFirst(2), radix: 16) else { return nil }
            out.append(word)
        }
        return out
    }

    public var isBinary: Bool { words != nil }

    /// What the key holds, for the keys this project knows (docs/diags-boot.md).
    public var meaning: String? { Self.knownKeys[key] }

    public static let knownKeys: [String: String] = [
        "SrNm": "Serial number",
        "MLB#": "Logic board (MLB) serial",
        "Mod#": "Model number",
        "Regn": "Region",
        "RMd#": "Regulatory model",
        "CFG#": "Config number",
        "WMac": "Wi-Fi MAC address",
        "BMac": "Bluetooth MAC address",
        "EMac": "Ethernet MAC address",
        "WCAL": "Wi-Fi calibration",
        "BCAL": "Bluetooth calibration",
        "SpEQ": "Speaker EQ calibration",
        "SpGa": "Speaker gain calibration",
        "MiGa": "Microphone gain calibration",
        "WFEQ": "Woofer EQ calibration",
        "LEDc": "LED calibration",
        "LSCI": "Light sensor calibration",
        "DClr": "Device colour",
    ]
}

public enum DiagsSerialError: Error, Equatable, LocalizedError {
    /// The line can't be sent as one command (empty, or contains a line break
    /// or control character that would start a second command).
    case invalidCommand(String)
    /// Not a four-character SysCfg key.
    case invalidKey(String)
    /// A SysCfg value that is empty or contains control characters.
    case invalidValue
    /// Not something that can be written as a model number (`Mod#`).
    case invalidModel(String)
    /// The model number was written, but reading `Mod#` back didn't give it.
    case modelNotVerified(expected: String, found: String)
    /// The shell never printed its prompt.
    case noPrompt(partial: String)
    /// The command started but its prompt never came back.
    case commandTimedOut(command: String, partial: String)
    /// `cancelCurrentCommand()` was called while waiting for the prompt.
    case commandCancelled(command: String, partial: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCommand(let line):
            return line.isEmpty ? "Type a command first." : "That can't be sent as a single command (it contains a line break or control character)."
        case .invalidKey(let key):
            return "\"\(key)\" isn't a SysCfg key. Keys are exactly four characters, like SrNm or MLB#."
        case .invalidValue:
            return "Enter a value (plain text, on one line)."
        case .invalidModel(let model):
            return model.isEmpty
                ? "Enter a model number, like MQHW2."
                : "\"\(model)\" can't be written as a model number. Use 4 to 16 letters, digits, \"/\" or \"-\", with no spaces — like MQHW2 or MQHV2LL/A."
        case .modelNotVerified(let expected, let found):
            return found.isEmpty
                ? "Mod# did not read back after the write (expected \(expected)). The key may now be missing — check the output and write it again."
                : "Mod# read back as \"\(found)\", not \(expected). Check the output and write it again."
        case .noPrompt:
            return "No DIAGS prompt. Check that the pod has booted into Factory DIAGS, that this is the right serial port, and that the adapter's TX/RX aren't swapped."
        case .commandTimedOut(let command, _):
            return "\"\(command)\" didn't finish — the prompt never came back."
        case .commandCancelled(let command, _):
            return "Stopped waiting for \"\(command)\". The pod may still be running it."
        }
    }
}

public final class DiagsSerialSession: @unchecked Sendable {
    /// The tail of the prompt. The full prompt is `[ECID] :-) `.
    public static let promptMarker = ":-)"

    public let port: SerialPort
    /// Idle timeout for an ordinary command (seconds without any output).
    public var commandTimeout: TimeInterval = 10
    /// Idle timeout for commands that print a lot or work for a while.
    public var longCommandTimeout: TimeInterval = 30

    private let lock = NSRecursiveLock()
    private var _ecid: String?
    private var _lastPrompt: String?

    public init(port: SerialPort) {
        self.port = port
    }

    /// The unit's ECID (hex, as printed in the prompt), once a prompt was seen.
    public var ecid: String? {
        lock.lock(); defer { lock.unlock() }
        return _ecid
    }

    /// The last prompt line seen, e.g. `[00092951386A6F26] :-)`.
    public var lastPrompt: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastPrompt
    }

    // MARK: Prompt

    /// Nudges the shell with an empty line and waits for its `:-) ` prompt.
    /// Returns the prompt line (`[ECID] :-)`).
    public func waitForPrompt() throws -> String {
        try waitForPrompt(timeout: 5)
    }

    public func waitForPrompt(timeout: TimeInterval) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let raw: String
        do {
            raw = try port.sendAndCollect("", until: Self.promptMarker, timeout: timeout, maxDuration: max(timeout, 30))
        } catch SerialPortError.timeout(let partial) {
            throw DiagsSerialError.noPrompt(partial: Self.stripANSI(partial))
        }
        return notePrompt(in: raw) ?? Self.promptMarker
    }

    /// Text that arrived without being asked for (boot log, async messages),
    /// cleaned of colour codes. Empty when there's nothing new.
    public func readUnsolicited() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let text = try port.readAvailable()
        guard !text.isEmpty else { return "" }
        _ = notePrompt(in: text)
        return Self.normalizeNewlines(Self.stripANSI(text))
    }

    // MARK: Commands

    /// Sends one command and returns its output once the prompt is back.
    public func runCommand(_ command: String) throws -> DiagsCommandResult {
        try runCommand(command, timeout: nil)
    }

    /// `timeout` is an idle timeout (see `SerialPort.readUntil`); `nil` uses
    /// `commandTimeout`.
    public func runCommand(_ command: String, timeout: TimeInterval?) throws -> DiagsCommandResult {
        let line = try Self.validatedCommand(command)
        lock.lock(); defer { lock.unlock() }
        let raw: String
        do {
            raw = try port.sendAndCollect(line, until: Self.promptMarker, timeout: timeout ?? commandTimeout, maxDuration: 300)
        } catch SerialPortError.timeout(let partial) {
            throw DiagsSerialError.commandTimedOut(command: line, partial: Self.cleanOutput(partial, command: line))
        } catch SerialPortError.cancelled(let partial) {
            throw DiagsSerialError.commandCancelled(command: line, partial: Self.cleanOutput(partial, command: line))
        }
        _ = notePrompt(in: raw)
        return Self.result(command: line, rawOutput: raw)
    }

    /// Stops waiting for the command that is running now (it fails with
    /// `.commandCancelled`). Safe from any thread. Nothing is sent to the pod.
    public func cancelCurrentCommand() {
        port.cancelRead()
    }

    /// Runs several commands in order. A command that prints `ERROR:` doesn't
    /// stop the rest — each reading is independent — but a timeout or a
    /// disconnect does (it throws).
    public func runCommands(_ commands: [String], timeout: TimeInterval? = nil) throws -> [DiagsCommandResult] {
        lock.lock(); defer { lock.unlock() }
        return try commands.map { try runCommand($0, timeout: timeout) }
    }

    /// Runs a quick action's commands with the timeout that suits it.
    public func run(_ action: DiagsQuickAction) throws -> [DiagsCommandResult] {
        try runCommands(action.commands, timeout: action.isSlow ? longCommandTimeout : nil)
    }

    // MARK: SysCfg

    /// `syscfg list`, parsed. Use `runCommand("syscfg list")` when the raw
    /// text is wanted as well.
    public func syscfgList() throws -> [SysCfgEntry] {
        Self.parseSysCfgList(try runCommand("syscfg list", timeout: longCommandTimeout).cleanOutput)
    }

    /// `syscfg print <key>` — the value as DIAGS prints it.
    public func syscfgPrint(_ key: String) throws -> String {
        let key = try Self.validatedKey(key)
        let result = try runCommand("syscfg print \(key)", timeout: longCommandTimeout)
        return Self.valueFromPrint(result.cleanOutput, key: key)
    }

    /// `syscfg add <key> <value>`. WRITES FLASH.
    public func syscfgAdd(_ key: String, value: String) throws -> DiagsCommandResult {
        let key = try Self.validatedKey(key)
        let value = try Self.validatedValue(value)
        return try runCommand("syscfg add \(key) \(value)", timeout: longCommandTimeout)
    }

    /// `syscfg delete <key>`. WRITES FLASH.
    public func syscfgDelete(_ key: String) throws -> DiagsCommandResult {
        let key = try Self.validatedKey(key)
        return try runCommand("syscfg delete \(key)", timeout: longCommandTimeout)
    }

    /// `syscfg init` — creates an EMPTY SysCfg. WRITES FLASH and erases the
    /// identity and calibration of a working unit.
    public func syscfgInit() throws -> DiagsCommandResult {
        try runCommand("syscfg init", timeout: longCommandTimeout)
    }

    // MARK: Model reconfiguration (colour swap)
    //
    // A 1st-gen HomePod's colour is its model number: MQHW2 (Space Gray) or
    // MQHV2 (White) — see `HomePodModelVariant`. Changing it is three lines:
    // delete the key, add it with the new value, read it back.

    /// The SysCfg key that holds the model number.
    public static let modelKey = "Mod#"

    /// A model number that is safe to put on a `syscfg add` line: 4 to 16
    /// letters, digits, "/" or "-". No spaces — a space would split it into
    /// two arguments.
    public static func validatedModelNumber(_ model: String) throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        let allowed = trimmed.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2F || byte == 0x2D
        }
        guard (4...16).contains(trimmed.utf8.count), allowed else { throw DiagsSerialError.invalidModel(trimmed) }
        return trimmed
    }

    /// The three lines that change the model number, in order. WRITE FLASH.
    /// Throws before anything is sent when `newModel` isn't a model number.
    public static func modelReconfigureCommands(to newModel: String) throws -> [String] {
        let model = try validatedModelNumber(newModel)
        return ["syscfg delete \(modelKey)", "syscfg add \(modelKey) \(model)", "syscfg print \(modelKey)"]
    }

    /// The model number read back by the last of `modelReconfigureCommands`.
    /// Throws `.modelNotVerified` unless it is exactly `expected` — the
    /// read-back is the proof, whatever the delete and add lines printed (the
    /// delete of a key that was never set is allowed to complain).
    public static func verifiedModel(from results: [DiagsCommandResult], expected: String) throws -> String {
        let expected = try validatedModelNumber(expected)
        guard results.count == 3, !results[2].hasError else {
            throw DiagsSerialError.modelNotVerified(expected: expected, found: "")
        }
        let found = valueFromPrint(results[2].cleanOutput, key: modelKey)
        guard found == expected else {
            throw DiagsSerialError.modelNotVerified(expected: expected, found: String(found.prefix(80)))
        }
        return found
    }

    /// Changes the unit's model number (`Mod#`) — and with it the colour the
    /// system reports. WRITES FLASH. Sends `syscfg delete Mod#`,
    /// `syscfg add Mod# <newModel>` and `syscfg print Mod#`, and returns the
    /// value read back. Throws `.modelNotVerified` when the read-back isn't
    /// the new model.
    @discardableResult
    public func reconfigureModel(to newModel: String) throws -> String {
        let commands = try Self.modelReconfigureCommands(to: newModel)
        let results = try runCommands(commands, timeout: longCommandTimeout)
        return try Self.verifiedModel(from: results, expected: newModel)
    }

    // MARK: Grouped readings
    //
    // Each returns one block of text: every command as `> command` followed by
    // its cleaned output.

    public func readSystemInfo() throws -> String { try transcript(.systemInfo) }
    public func readNANDInfo() throws -> String { try transcript(.nandHealth) }
    public func readSensorData() throws -> String { try transcript(.sensors) }
    /// Initialises the amp controller — the first step of an audio test.
    /// Bare `playaudio` / `recordaudio` are not sent by any action: they only
    /// answer "Both Blockname and Portnames have to be provided!".
    public func runAudioTest() throws -> String { try transcript(.audioInit) }
    /// Amp init, then a 1 kHz tone for 3 s. Blocks until the tone has ended.
    /// Amp init, then the 100 Hz – 10 kHz tone sweep (about 9 s in all).
    /// `stopaudio` — ends an `--async` play / record session.
    /// The Wi-Fi command's usage (`help wifi`). Bare `wifi` only answers
    /// "No option specified", and no read-only option has been captured yet.
    public func runWiFiTest() throws -> String { try transcript(.wifi) }
    /// The Bluetooth command's usage (`help bluetooth`), for the same reason.
    public func runBluetoothTest() throws -> String { try transcript(.bluetooth) }

    private func transcript(_ kind: DiagsQuickAction.Kind) throws -> String {
        Self.transcript(try run(DiagsQuickAction.action(kind)))
    }

    /// `> command` + output for each result, separated by blank lines.
    public static func transcript(_ results: [DiagsCommandResult]) -> String {
        results.map { result in
            result.cleanOutput.isEmpty ? "> \(result.command)" : "> \(result.command)\n\(result.cleanOutput)"
        }.joined(separator: "\n\n")
    }

    // MARK: Parsing (pure — no port needed)

    /// Removes ANSI / VT100 escape sequences: colours (`ESC[0;31m`), cursor
    /// movement, OSC strings and stray two-character escapes.
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") || text.contains("\u{9B}") else { return text }
        var out = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?

        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let scalar = next() {
            let isCSI8 = scalar == "\u{9B}"
            guard scalar == "\u{1B}" || isCSI8 else { out.append(scalar); continue }
            guard let intro: Unicode.Scalar = isCSI8 ? "[" : next() else { break }  // lone ESC at the end
            switch intro {
            case "[":
                // CSI: parameter/intermediate bytes, then one final byte @…~.
                while let c = next() {
                    if c.value >= 0x40 && c.value <= 0x7E { break }
                    // A control character inside a sequence means it was cut
                    // short; keep the character (it may be a newline).
                    if c.value < 0x20 { pending = c; break }
                }
            case "]":
                // OSC: up to BEL or ESC \.
                while let c = next() {
                    if c == "\u{07}" { break }
                    if c == "\u{1B}" { _ = next(); break }
                    if c == "\n" { pending = c; break }
                }
            case "(", ")", "*", "+":
                _ = next()  // charset designation: one more byte
            case "\u{1B}":
                pending = intro  // ESC ESC — treat the second as a new escape
            default:
                break  // two-character escape (ESC c, ESC =, …)
            }
        }
        return String(out)
    }

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Raw reply → what the command itself printed: colour codes gone, line
    /// endings normalised, the echoed command and the closing prompt removed.
    public static func cleanOutput(_ raw: String, command: String) -> String {
        var lines = normalizeNewlines(stripANSI(raw))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { applyBackspaces(String($0)) }

        // Closing prompt: the last line, when it carries the marker.
        if let last = lines.last, last.contains(promptMarker) { lines.removeLast() }

        // Echo: the first non-blank line, if it is the command (possibly with
        // the prompt in front of it, when the shell redraws the line).
        let wanted = command.trimmingCharacters(in: .whitespaces)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            var candidate = lines[first]
            if let marker = candidate.range(of: promptMarker) { candidate = String(candidate[marker.upperBound...]) }
            if candidate.trimmingCharacters(in: .whitespaces) == wanted {
                lines.removeSubrange(...first)
            }
        }

        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.map { trimTrailingWhitespace($0) }.joined(separator: "\n")
    }

    static func result(command: String, rawOutput: String) -> DiagsCommandResult {
        let clean = cleanOutput(rawOutput, command: command)
        return DiagsCommandResult(command: command, rawOutput: rawOutput, cleanOutput: clean,
                                  exitCode: parseExitCode(clean), hasError: containsErrorLine(clean))
    }

    /// The last `Exit code = 0x…` in the text, as printed (`0x00000000`).
    public static func parseExitCode(_ text: String) -> String? {
        var found: String?
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "Exit code", options: .caseInsensitive) else { continue }
            let rest = line[range.upperBound...].drop { $0 == " " || $0 == "=" || $0 == ":" || $0 == "\t" }
            guard rest.lowercased().hasPrefix("0x") else { continue }
            let digits = rest.dropFirst(2).prefix { $0.isHexDigit }
            if !digits.isEmpty { found = "0x" + digits }
        }
        return found
    }

    /// Whether any line starts with `ERROR:` (leading whitespace allowed).
    public static func containsErrorLine(_ text: String) -> Bool {
        text.split(separator: "\n").contains { $0.drop { $0 == " " || $0 == "\t" }.hasPrefix("ERROR:") }
    }

    /// The prompt line inside `text`, with the ECID if it has one.
    public static func prompt(in text: String) -> (line: String, ecid: String?)? {
        let clean = normalizeNewlines(stripANSI(text))
        guard let line = clean.split(separator: "\n").last(where: { $0.contains(promptMarker) }),
              let marker = line.range(of: promptMarker, options: .backwards) else { return nil }
        let head = line[..<marker.lowerBound]
        var ecid: String?
        if let close = head.lastIndex(of: "]"), let open = head[..<close].lastIndex(of: "[") {
            let inside = head[head.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let hex = inside.lowercased().hasPrefix("0x") ? String(inside.dropFirst(2)) : inside
            if !hex.isEmpty, hex.allSatisfy(\.isHexDigit) { ecid = hex.uppercased() }
        }
        let start = head.lastIndex(of: "[") ?? marker.lowerBound
        return (String(line[start..<marker.upperBound]), ecid)
    }

    /// Parses `syscfg list` output. DIAGS prints one entry per line as
    /// `Key: SrNm = CC4VKKTQHQK8`; a long binary value may continue on
    /// following lines of hex words, which are joined to the entry.
    public static func parseSysCfgList(_ text: String) -> [SysCfgEntry] {
        var entries: [(key: String, value: String)] = []
        for rawLine in normalizeNewlines(stripANSI(text)).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains(promptMarker) else { continue }
            if let (key, value) = sysCfgKeyValue(line) {
                entries.append((key, value))
            } else if !entries.isEmpty, isHexWordLine(line) {
                let previous = entries[entries.count - 1].value
                entries[entries.count - 1].value = previous.isEmpty ? line : previous + " " + line
            }
        }
        // A key listed twice keeps its last value but its first position.
        var order: [String] = []
        var values: [String: String] = [:]
        for entry in entries {
            if values[entry.key] == nil { order.append(entry.key) }
            values[entry.key] = entry.value
        }
        return order.map { SysCfgEntry(key: $0, value: values[$0] ?? "") }
    }

    private static func sysCfgKeyValue(_ line: String) -> (String, String)? {
        var body = Substring(line)
        var hadPrefix = false
        if body.lowercased().hasPrefix("key:") {
            body = body.dropFirst(4).drop { $0 == " " || $0 == "\t" }
            hadPrefix = true
        }
        guard let equals = body.firstIndex(of: "=") else { return nil }
        let key = body[..<equals].trimmingCharacters(in: .whitespaces)
        guard isSysCfgKey(key) else { return nil }
        // Without the `Key:` label only accept the exact `XXXX = value` shape,
        // so ordinary output that happens to contain "=" isn't taken as a key.
        if !hadPrefix {
            guard body[..<equals].hasSuffix(" "), body.distance(from: body.startIndex, to: equals) == 5 else { return nil }
        }
        let value = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func isHexWordLine(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return !tokens.isEmpty && tokens.allSatisfy { token in
            token.lowercased().hasPrefix("0x") && token.count > 2 && token.dropFirst(2).allSatisfy(\.isHexDigit)
        }
    }

    /// The value part of `syscfg print KEY` output. DIAGS may print just the
    /// value or a `Key: KEY = value` line; either way the value comes back.
    public static func valueFromPrint(_ clean: String, key: String) -> String {
        if let entry = parseSysCfgList(clean).first(where: { $0.key == key }) { return entry.value }
        return clean.split(separator: "\n")
            .filter { !$0.contains("Exit code") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Validation

    /// Four printable ASCII characters, no spaces: `SrNm`, `MLB#`, `CFG#`.
    public static func isSysCfgKey(_ key: String) -> Bool {
        key.utf8.count == 4 && key.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    static func validatedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard isSysCfgKey(trimmed) else { throw DiagsSerialError.invalidKey(trimmed) }
        return trimmed
    }

    static func validatedValue(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: isControl) else {
            throw DiagsSerialError.invalidValue
        }
        return trimmed
    }

    /// One line, no control characters — so a pasted value can never smuggle a
    /// second command (`…\nsyscfg init`) onto the wire.
    public static func validatedCommand(_ command: String) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: isControl) else {
            throw DiagsSerialError.invalidCommand(trimmed)
        }
        return trimmed
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (scalar.value >= 0x80 && scalar.value < 0xA0)
    }

    // MARK: Small helpers

    private func notePrompt(in text: String) -> String? {
        guard let found = Self.prompt(in: text) else { return nil }
        _lastPrompt = found.line
        if let ecid = found.ecid { _ecid = ecid }
        return found.line
    }

    /// Applies backspaces the way a terminal would (`ab\u{8}c` → `ac`), for
    /// shells that redraw the line while echoing.
    private static func applyBackspaces(_ line: String) -> String {
        guard line.contains("\u{08}") else { return line }
        var out: [Character] = []
        for ch in line {
            if ch == "\u{08}" { if !out.isEmpty { out.removeLast() } } else { out.append(ch) }
        }
        return String(out)
    }

    private static func trimTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let before = line.index(before: end)
            guard line[before] == " " || line[before] == "\t" else { break }
            end = before
        }
        return String(line[..<end])
    }
}

// MARK: - Quick actions
//
// The button-driven DIAGS screen runs these. Labels, grouping and risk come
// from `DiagsCommandReference`, so the screen and the reference card can't
// drift apart; only the command lines themselves live here.
//
// Every line here goes to a real HomePod, so the rule is: only lines that have
// been run on a real unit, or that appear verbatim in Apple's factory scripts.
// Where a command's arguments aren't known the button sends `help <command>`
// instead of guessing — a wrong guess costs the tech a reboot.
//
// The one exception is the tone buttons (Test Tone, Tone Sweep). Their
// `playaudio` lines are built from the `help playaudio` text and the
// `--listcaps` output of a real unit, but had NOT been played on one when they
// were added. They name the playable block (socmca) and no port: the port
// names haven't been captured, and the shell's own error is expected to say
// whether one is needed. Once a line has played on a real unit, add the port
// in `DiagsCommandReference.toneLine` if it wants one and drop this paragraph.
//
// The second exception is NVRAM: `nvram -p` is a guess at the print option and
// is labelled as one on the button. If it turns out wrong, change the line to
// `help nvram`.
//
// No button writes flash. Changing the model number (colour) writes SysCfg, so
// it goes through its own sheet — `reconfigureModel(to:)` above — like the
// SysCfg write form.
//
// NEVER add `NANDInfoTool`: it panics DIAGS (null-pointer dereference in
// TestNand.macho) and the pod drops to DFU. Bare `nand`, `temperature`,
// `sensor`, `wifi`, `bluetooth`, `playaudio` and `recordaudio` only print a
// usage error, so they aren't sent either.

public struct DiagsQuickAction: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case systemInfo, sysCfgList, readSerial, nandHealth
        case audioInit, audioInfo, audioHelp
        case sensors, wifi, bluetooth, ledOn, ledOff
        // Device info
        case system, socInfo, bootConfig
        // Factory history
        case controlBits, controlBitDump
        // Power / PMU
        case pmuEvents, pmuADC, pmuRegisters, buckCheck, rtc
        // NAND
        case nandTests, nandParams
        // Memory
        case memoryInfo, memoryMap
        // Storage
        case filesystem, nvram
        // LED colours
        case ledRed, ledGreen, ledBlue, ledWhite
        public var id: String { rawValue }
    }

    public let kind: Kind
    /// Button label.
    public let title: String
    /// SF Symbol name for the button.
    public let symbol: String
    /// The reference category the action belongs to (its title and blurb head
    /// the group of buttons).
    public let category: DiagsCommand.Category
    /// The command lines, sent in order.
    public let commands: [String]

    public var id: String { kind.rawValue }

    /// The most serious risk among the action's command lines, per the
    /// reference. A line the reference doesn't know counts as `.unknown`.
    public var risk: DiagsCommand.Risk {
        commands.map { DiagsCommandReference.risk(ofLine: $0) ?? .unknown }
            .max { Self.rank($0) < Self.rank($1) } ?? .unknown
    }

    /// Prints a lot or works for a while — gets the long timeout. The tone
    /// actions are here because a synchronous `playaudio` prints nothing until
    /// its tone has ended (3 s at most), and the timeout is an idle timeout.
    public var isSlow: Bool {
        switch kind {
        case .sysCfgList, .nandHealth, .audioInit, .audioInfo, .audioHelp,
             .sensors, .wifi, .bluetooth: return true
        // Long print-outs: 256 control-bit stations, register and memory dumps.
        case .controlBits, .controlBitDump, .pmuEvents, .pmuADC, .pmuRegisters, .buckCheck,
             .nandTests, .nandParams, .memoryInfo, .memoryMap, .filesystem, .nvram: return true
        default: return false
        }
    }

    /// Makes sound, or stops it. The screen shows these as their own row of
    /// the Audio group, apart from the bring-up and read-out buttons.
    public var isAudioPlayback: Bool {
        switch kind {
        default: return false
        }
    }

    /// What the button does that the per-command summaries don't say.
    public var note: String? {
        switch kind {
        case .controlBits:
            return "The unit's factory test-station history: which stations it passed. Long output (256 stations) — scroll, or save it."
        case .pmuEvents:
            return "Latched PMU fault and voltage events — the first thing to read on a board that won't stay up."
        case .pmuADC:
            return "Sends `help pmuadc`: the channel arguments haven't been captured yet, so this prints the usage instead of guessing."
        case .nandTests:
            return "Lists the available NAND tests. It does not run any of them."
        case .nvram:
            return "`nvram -p` is a guess at the print option. If it errors, type `help nvram`."
        case .ledGreen:
            return "Same pattern as red and blue, which are confirmed on a real unit; green itself isn't yet."
        case .ledWhite:
            return "Sets red, green and blue one after another, which mixes to white."
        default:
            return nil
        }
    }

    /// The button's own note (if any), then one line per command: what the
    /// reference says it does.
    public var help: String {
        var seen = Set<String>()
        let lines = commands.compactMap { line -> String? in
            guard let command = DiagsCommandReference.command(forLine: line), seen.insert(command.name).inserted else { return nil }
            return "\(command.name) — \(command.summary)"
        }
        return ((note.map { [$0] } ?? []) + lines + ["Risk: \(risk.title)"]).joined(separator: "\n")
    }

    static func rank(_ risk: DiagsCommand.Risk) -> Int {
        switch risk {
        case .readOnly: return 0
        case .changesState: return 1
        case .unknown: return 2
        case .writesFlash: return 3
        case .crashesDevice: return 4
        }
    }

    public static let all: [DiagsQuickAction] = [
        DiagsQuickAction(kind: .systemInfo, title: "System Info", symbol: "info.circle", category: .deviceInfo,
                         commands: ["sysinfo", "version", "boardid", "boardrev", "chipid"]),
        DiagsQuickAction(kind: .system, title: "System", symbol: "hifispeaker.fill", category: .deviceInfo,
                         commands: ["system"]),
        DiagsQuickAction(kind: .socInfo, title: "SoC Info", symbol: "cpu", category: .deviceInfo,
                         commands: ["soc"]),
        DiagsQuickAction(kind: .bootConfig, title: "Boot Config", symbol: "gearshape.2", category: .deviceInfo,
                         commands: ["bootcfg"]),
        DiagsQuickAction(kind: .controlBits, title: "Control Bits", symbol: "checklist", category: .factoryHistory,
                         commands: ["cbreadall"]),
        DiagsQuickAction(kind: .controlBitDump, title: "Control Bit Dump", symbol: "doc.plaintext", category: .factoryHistory,
                         commands: ["cbdump"]),
        DiagsQuickAction(kind: .sysCfgList, title: "SysCfg List", symbol: "list.bullet.rectangle", category: .sysCfg,
                         commands: ["syscfg list"]),
        DiagsQuickAction(kind: .readSerial, title: "Read Serial", symbol: "number", category: .sysCfg,
                         commands: ["sn"]),
        DiagsQuickAction(kind: .nandHealth, title: "NAND Health", symbol: "internaldrive", category: .nand,
                         commands: ["nandcsid", "nandppnfwver", "nanduid", "blockdevice"]),
        // `--testlist` only lists the tests; nothing here runs one.
        DiagsQuickAction(kind: .nandTests, title: "NAND Tests", symbol: "list.bullet.clipboard", category: .nand,
                         commands: ["nand --testlist"]),
        DiagsQuickAction(kind: .nandParams, title: "NAND Params", symbol: "slider.horizontal.3", category: .nand,
                         commands: ["nand --getinfo"]),
        DiagsQuickAction(kind: .filesystem, title: "Filesystem", symbol: "folder", category: .storage,
                         commands: ["dir fs0:", "dir nandfs:"]),
        DiagsQuickAction(kind: .nvram, title: "NVRAM", symbol: "tray.full", category: .storage,
                         commands: ["nvram -p"]),
        DiagsQuickAction(kind: .memoryInfo, title: "Memory Info", symbol: "memorychip", category: .memory,
                         commands: ["memory --info", "memory --list"]),
        DiagsQuickAction(kind: .memoryMap, title: "Memory Map", symbol: "map", category: .memory,
                         commands: ["dumpmemmap"]),
        DiagsQuickAction(kind: .audioInit, title: "Amp Init", symbol: "hifispeaker", category: .audio,
                         commands: ["ampcontroller --init"]),
        DiagsQuickAction(kind: .audioInfo, title: "Volume & Audio Caps", symbol: "speaker.wave.2", category: .audio,
                         commands: ["getvol", "playaudio --listcaps"]),
        DiagsQuickAction(kind: .audioHelp, title: "Play/Record Help", symbol: "questionmark.circle", category: .audio,
                         commands: ["help playaudio", "help recordaudio"]),
        // pmutemp first: it is the one confirmed on a real unit. The next two
        // are verbatim from Apple's sochot.sh; `pmustat all` is unconfirmed.
        DiagsQuickAction(kind: .sensors, title: "Thermal/Sensors", symbol: "thermometer", category: .sensor,
                         commands: ["pmutemp", "temperature --all", "sensor -s touch --get temp", "pmustat all"]),
        DiagsQuickAction(kind: .pmuEvents, title: "PMU Events", symbol: "exclamationmark.triangle", category: .power,
                         commands: ["pmuevent all"]),
        // The ADC's channel arguments aren't known yet: ask the shell.
        DiagsQuickAction(kind: .pmuADC, title: "PMU ADC", symbol: "gauge", category: .power,
                         commands: ["help pmuadc"]),
        DiagsQuickAction(kind: .pmuRegisters, title: "PMU Registers", symbol: "tablecells", category: .power,
                         commands: ["pmureg"]),
        DiagsQuickAction(kind: .buckCheck, title: "Buck Check", symbol: "bolt", category: .power,
                         commands: ["buckcheck"]),
        DiagsQuickAction(kind: .rtc, title: "RTC", symbol: "clock", category: .power,
                         commands: ["rtc --get"]),
        DiagsQuickAction(kind: .wifi, title: "WiFi Info", symbol: "wifi", category: .radio,
                         commands: ["wifi --list", "wifi --get", "wifi --properties"]),
        DiagsQuickAction(kind: .bluetooth, title: "Bluetooth Info", symbol: "dot.radiowaves.left.and.right", category: .radio,
                         commands: ["bluetooth --list", "bluetooth --properties"]),
        DiagsQuickAction(kind: .ledOn, title: "LED On", symbol: "lightbulb.fill", category: .led,
                         commands: ["strobe -c led --power on"]),
        DiagsQuickAction(kind: .ledOff, title: "LED Off", symbol: "lightbulb.slash", category: .led,
                         commands: ["strobe -c led --power off"]),
        // Red and blue are confirmed on a real unit; green follows the pattern.
        DiagsQuickAction(kind: .ledRed, title: "LED Red", symbol: "r.circle.fill", category: .led,
                         commands: [ledColorLine("red")]),
        DiagsQuickAction(kind: .ledGreen, title: "LED Green", symbol: "g.circle.fill", category: .led,
                         commands: [ledColorLine("green")]),
        DiagsQuickAction(kind: .ledBlue, title: "LED Blue", symbol: "b.circle.fill", category: .led,
                         commands: [ledColorLine("blue")]),
        // All three channels on = white.
        DiagsQuickAction(kind: .ledWhite, title: "LED White", symbol: "w.circle.fill", category: .led,
                         commands: [ledColorLine("red"), ledColorLine("green"), ledColorLine("blue")]),
    ]

    /// Brightness level the LED colour buttons use (the one confirmed on a real unit).
    public static let ledLevel = 25

    /// `strobe -c led -s All_RGB --set <colour> 25`
    static func ledColorLine(_ colour: String) -> String {
        "strobe -c led -s All_RGB --set \(colour) \(ledLevel)"
    }

    public static func action(_ kind: Kind) -> DiagsQuickAction {
        // `all` covers every kind (checked by a unit test).
        all.first { $0.kind == kind }!
    }

    /// The reference categories that have quick actions, in the order the
    /// actions are listed above (device info first, as at the bench).
    public static var categories: [DiagsCommand.Category] {
        var seen: [DiagsCommand.Category] = []
        for action in all where !seen.contains(action.category) { seen.append(action.category) }
        return seen
    }

    public static func actions(in category: DiagsCommand.Category) -> [DiagsQuickAction] {
        all.filter { $0.category == category }
    }
}
