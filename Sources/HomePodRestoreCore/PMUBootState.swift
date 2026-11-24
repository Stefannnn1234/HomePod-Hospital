import Foundation

/// iBoot's boot bookkeeping in the power chip.
///
/// The HomePod's PMU is a Dialog D2186 (Apple: "Adi") on I2C0 at 0x74, with
/// 16-bit register addresses sent high byte first. iBoot keeps a small NVRAM
/// in the PMU's scratch area at 0x4000, which survives a SoC reset (but not a
/// full power-off). Offsets per Apple's Astris PMU support scripts:
///
///     0x4000  debug        0x400D  boot flags 0
///     0x4001  stage        0x400E  boot flags 1
///     0x4002  error count  0x400F  state
///     0x4003  error stage  0x4014  enter-DFU request (0xA0 = set)
///
/// Writing 0xA0 to 0x4014 and resetting the SoC is how Apple's tooling puts a
/// HomePod into DFU without buttons ("soft DFU"). The D2186 can't force
/// SecureROM DFU, so this lands in LLB DFU: checkm8 / gaster won't work there.
public struct PMUBootState: Equatable, Sendable {
    public static let scratchBase: UInt16 = 0x4000
    public static let length = 0x15
    public static let enterDFURegister: UInt16 = 0x4014
    public static let enterDFUValue: UInt8 = 0xA0
    /// The DIAGS line that reads the whole area.
    public static let diagsReadCommand = "pmurw -r 0x4000 \(length)"

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count >= Self.length else { return nil }
        self.bytes = Array(bytes.prefix(Self.length))
    }

    public var debug: UInt8 { bytes[0x00] }
    public var stage: UInt8 { bytes[0x01] }
    public var errorCount: UInt8 { bytes[0x02] }
    public var errorStage: UInt8 { bytes[0x03] }
    public var bootFlags0: UInt8 { bytes[0x0D] }
    public var bootFlags1: UInt8 { bytes[0x0E] }
    public var state: UInt8 { bytes[0x0F] }
    public var enterDFU: UInt8 { bytes[0x14] }
    public var dfuRequested: Bool { enterDFU == Self.enterDFUValue }

    /// One-paragraph reading for the DIAGS log.
    public var summary: String {
        func h(_ v: UInt8) -> String { String(format: "0x%02X", v) }
        var lines = [
            "iBoot boot state (PMU scratch 0x4000–0x4014):",
            "  boot errors: \(errorCount)" + (errorCount > 0 ? " — last one at stage \(h(errorStage))" : ""),
            "  stage \(h(stage)), state \(h(state)), flags \(h(bootFlags0)) \(h(bootFlags1)), debug \(h(debug))",
            "  DFU request: " + (dfuRequested ? "SET — the next reset goes to DFU (LLB DFU, not SecureROM)" : (enterDFU == 0 ? "none" : "\(h(enterDFU)) (not the 0xA0 trigger)")),
        ]
        if errorCount > 0 {
            lines.append("  A nonzero error count means iBoot failed to boot recently. Compare the stage with a pod that boots.")
        }
        return lines.joined(separator: "\n")
    }

    /// Pull the register bytes out of `pmurw -r 0x4000 21` output. The exact
    /// print format isn't captured yet, so this takes byte-sized hex values in
    /// order and skips an "address:" column if there is one. nil when fewer
    /// than 21 bytes come out.
    public static func parse(pmurwOutput text: String) -> PMUBootState? {
        var bytes: [UInt8] = []
        let token = try! NSRegularExpression(pattern: #"(?<![0-9A-Za-z])(?:0x)?([0-9A-Fa-f]{2})(?![0-9A-Za-z])"#)
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw)
            // Echoed command or prompt lines carry the address, not data.
            if line.contains("pmurw") || line.contains("]") { continue }
            if let colon = line.lastIndex(of: ":") { line = String(line[line.index(after: colon)...]) }
            let ns = line as NSString
            for m in token.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                if let v = UInt8(ns.substring(with: m.range(at: 1)), radix: 16) { bytes.append(v) }
            }
        }
        return PMUBootState(bytes: bytes)
    }
}
