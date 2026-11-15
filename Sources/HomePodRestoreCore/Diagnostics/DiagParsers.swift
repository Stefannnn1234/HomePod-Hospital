import Foundation

// MARK: - Diagnostic output parsers
//
// Pure functions: pod output text in, typed result out. No I/O, so every one of
// them is unit-testable on Linux with captured text.
//
// Wire format, and why (same reasoning as the SysCfg transport): the SSH
// runner hands back combined stdout/stderr as text, so the pod-side JSON can
// be surrounded by dropbear banners, shell warnings and stderr from `ioreg`.
// Each tool's JSON is therefore framed in explicit sentinels, and we carve it
// out — the same pattern as `SSHRamdiskTransport.extractBetweenMarkers`.

public enum DiagParseError: Error, LocalizedError, Equatable {
    /// The script isn't in this ramdisk (shell exit 127 / "not found").
    case toolMissing
    /// Nothing that looks like JSON came back. Carries the script's exit status.
    case noPayload(exitStatus: Int?)
    /// A payload was found but isn't the JSON object we expect.
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing:
            return "This check isn't in the ramdisk on this pod. Rebuild the SSH ramdisk so it includes the diagnostic scripts."
        case .noPayload(let status):
            if let status, status != 0 { return "The check exited with status \(status) without reporting a result." }
            return "The check ran but didn't report a result."
        case .invalidJSON(let why):
            return "The check's result couldn't be read (\(why))."
        }
    }
}

public enum DiagParsers {

    // MARK: Sentinel extraction

    /// Extract the JSON between `===HPDIAG_JSON_BEGIN===` and
    /// `===HPDIAG_JSON_END===`.
    ///
    /// Tolerant on purpose:
    /// - ANSI colour codes are stripped first (ioreg colourizes).
    /// - Nested markers (wrapper + a script that frames itself) resolve to the
    ///   innermost pair.
    /// - A missing end marker (truncated output) or no markers at all (a script
    ///   run by hand) falls back to the text that is there.
    /// - Inside the frame, anything before the JSON object's opening brace or
    ///   after its closing brace (stderr noise) is dropped.
    static func extractJSON(from output: String) throws -> Data {
        let clean = SSHRamdiskTransport.stripAnsi(output)
        let status = exitStatus(from: clean)
        let framed = extractBetweenMarkers(clean) ?? withoutExitMarker(clean)

        guard let json = jsonObjectText(in: framed) else {
            if status == 127 || looksLikeCommandNotFound(clean) { throw DiagParseError.toolMissing }
            throw DiagParseError.noPayload(exitStatus: status)
        }
        return Data(json.utf8)
    }

    /// Text between the innermost marker pair, trimmed. `nil` when no begin
    /// marker is present or the frame is empty.
    static func extractBetweenMarkers(_ text: String,
                                      begin: String = DiagCommands.beginMarker,
                                      end: String = DiagCommands.endMarker) -> String? {
        let endRange = text.range(of: end)
        let head = endRange.map { text[..<$0.lowerBound] } ?? text[...]
        guard let beginRange = head.range(of: begin, options: .backwards) else { return nil }
        let inner = head[beginRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// The script's exit status from the `===HPDIAG_EXIT=<n>===` trailer that
    /// `DiagCommands.invocation` appends. `nil` when the trailer is absent.
    static func exitStatus(from output: String) -> Int? {
        guard let r = output.range(of: DiagCommands.exitMarkerPrefix, options: .backwards) else { return nil }
        let digits = output[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func withoutExitMarker(_ text: String) -> String {
        guard let r = text.range(of: DiagCommands.exitMarkerPrefix, options: .backwards) else { return text }
        return String(text[..<r.lowerBound])
    }

    private static func looksLikeCommandNotFound(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("hpdiag-") && (lower.contains("not found") || lower.contains("no such file"))
    }

    /// The JSON object inside `text`: from an opening brace to the last closing
    /// brace. Tries the first brace, then each brace that starts a line, and
    /// returns the first candidate that is valid JSON.
    private static func jsonObjectText(in text: String) -> String? {
        guard let last = text.lastIndex(of: "}") else { return nil }
        var starts: [String.Index] = []
        if let first = text.firstIndex(of: "{") { starts.append(first) }
        var lineStart = true
        var i = text.startIndex
        while i < last {
            let ch = text[i]
            if ch == "{", lineStart, !starts.contains(i) { starts.append(i) }
            if ch == "\n" { lineStart = true } else if !ch.isWhitespace { lineStart = false }
            i = text.index(after: i)
        }
        for start in starts where start < last {
            let candidate = String(text[start...last])
            if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) is [String: Any] { return candidate }
        }
        // Nothing validated: hand back the widest span so the decoder can say why.
        return starts.first.flatMap { $0 < last ? String(text[$0...last]) : nil }
    }

    // MARK: Decoding

    /// Carve the JSON out of `output` and decode it as `T`.
    static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        let data = try extractJSON(from: output)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw DiagParseError.invalidJSON(describe(error))
        } catch {
            throw DiagParseError.invalidJSON(error.localizedDescription)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let c): return c.debugDescription
        case .keyNotFound(let k, _): return "missing \"\(k.stringValue)\""
        case .typeMismatch(_, let c): return c.debugDescription
        case .valueNotFound(_, let c): return c.debugDescription
        @unknown default: return "not valid JSON"
        }
    }

    // MARK: Per-tool parsers

    /// `hpdiag-nand` → NAND controller status, chip identity / geometry and
    /// block-layer I/O error counters (this controller publishes no wear figures).
    public static func parseNAND(_ output: String) throws -> NANDHealth {
        try decode(NANDHealth.self, from: output)
    }

    /// `hpdiag-partmap` → block devices and firmware-region validity.
    public static func parsePartMap(_ output: String) throws -> PartitionMap {
        try decode(PartitionMap.self, from: output)
    }

    /// `hpdiag-factory` → SysCfg tag completeness and effaceable lockers.
    public static func parseFactory(_ output: String) throws -> FactoryData {
        try decode(FactoryData.self, from: output)
    }

    /// `hpdiag-thermal` → temperature sensors.
    public static func parseThermal(_ output: String) throws -> ThermalSnapshot {
        try decode(ThermalSnapshot.self, from: output)
    }

    /// `hpdiag-power` → USB link and PMU state.
    public static func parsePower(_ output: String) throws -> PowerStatus {
        try decode(PowerStatus.self, from: output)
    }

    /// `hpdiag-radio` → Wi-Fi / Bluetooth presence and MACs.
    public static func parseRadio(_ output: String) throws -> RadioStatus {
        try decode(RadioStatus.self, from: output)
    }

    /// `hpdiag-audio` → codec / amp enumeration and per-channel faults.
    public static func parseAudio(_ output: String) throws -> AudioStatus {
        try decode(AudioStatus.self, from: output)
    }

    /// `hpdiag-mic` or `hpdiag-accel` (or a combined sensors object) → presence.
    public static func parseSensors(_ output: String) throws -> SensorPresence {
        try decode(SensorPresence.self, from: output)
    }

    /// Both sensor scripts' outputs → one merged presence result.
    public static func parseSensors(mic: String, accel: String) throws -> SensorPresence {
        try parseSensors(mic).merging(try parseSensors(accel))
    }

    /// `hpdiag-full` → the whole report in one document.
    public static func parseFull(_ output: String) throws -> FullDiagnosticsReport {
        try decode(FullDiagnosticsReport.self, from: output)
    }

    /// Parse one tool's output into the wrapper the report stores.
    public static func parse(_ tool: DiagTool, output: String) throws -> DiagToolResult {
        switch tool {
        case .nand: return .nand(try parseNAND(output))
        case .partmap: return .partmap(try parsePartMap(output))
        case .factory: return .factory(try parseFactory(output))
        case .thermal: return .thermal(try parseThermal(output))
        case .power: return .power(try parsePower(output))
        case .radio: return .radio(try parseRadio(output))
        case .audio: return .audio(try parseAudio(output))
        case .mic, .accel:
            // The per-tool object only says "detected"; tell the decoder which
            // sensor it is talking about when the script omitted "tool".
            return .sensors(try parseSensorHalf(output, tool: tool))
        }
    }

    /// Decodes a single-sensor object, tagging it with its tool when the
    /// script left the `tool` key out.
    private static func parseSensorHalf(_ output: String, tool: DiagTool) throws -> SensorPresence {
        let data = try extractJSON(from: output)
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DiagParseError.invalidJSON("not a JSON object")
        }
        if object["tool"] == nil { object["tool"] = tool.rawValue }
        guard let tagged = try? JSONSerialization.data(withJSONObject: object) else {
            throw DiagParseError.invalidJSON("not a JSON object")
        }
        do { return try JSONDecoder().decode(SensorPresence.self, from: tagged) }
        catch { throw DiagParseError.invalidJSON(error.localizedDescription) }
    }
}
