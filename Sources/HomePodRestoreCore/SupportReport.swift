import Foundation

/// Builds the text people paste into Discord when asking for help, so the
/// first reply can be an answer instead of "can you send your log?".
public enum SupportReport {
    public static func make(appVersion: String, macOS: String, tools: [ToolStatus], device: ConnectedDevice?,
                            snapshot: RestoreJob.Snapshot?, firmware: FirmwareItem?, logTail: Int = 60) -> String {
        var s = "**HomePod Restore support report**\n```\n"
        s += "App: \(appVersion)   macOS: \(macOS)\n"
        if let fw = firmware { s += "Firmware: \(fw.displayName) [\(fw.origin.rawValue)]\n" }
        for t in tools {
            let where_ = t.path == nil ? "MISSING" : (t.isBundled ? "bundled" : t.path!.path)
            s += "Tool \(t.tool.rawValue): \(where_) \(t.version ?? "")\(t.warning != nil ? "  ⚠︎" : "")\n"
        }
        if let d = device {
            s += "Device: \(d.mode.displayName), \(d.portLabel), \(d.speedDescription)\n"
            if let ib = d.iboot {
                s += "  CPID: \(ib.cpid.map { String(format: "0x%X", $0) } ?? "?")  BDID: \(ib.bdid.map { String(format: "0x%X", $0) } ?? "?")  SRTG: \(ib.srtg ?? "?")  PWND: \(ib.pwnd ?? "no")\n"
            }
        }
        if let snap = snapshot {
            s += "Job: \(snap.kind.title) — \(snap.outcome)\n"
            s += "Reached: \(snap.phase.title) — \(snap.status)\n"
            if snap.unlockAttempts > 0 { s += "Unlock attempts: \(snap.unlockAttempts)\n" }
            let hw = snap.hardware
            if !hw.isEmpty {
                s += "Hardware: BoardID \(hw.boardID.map(String.init) ?? "?"), ChipID \(hw.chipID.map(String.init) ?? "?"), ProductionMode \(hw.productionMode.map { $0 ? "true" : "false" } ?? "?")\n"
            }
            if let n = hw.nandWaitSeconds { s += "NAND wait: \(Int(n))s\n" }
            let issues = snap.issues.filter { $0.severity != .normal }
            if !issues.isEmpty { s += "Detected: " + issues.map(\.title).joined(separator: "; ") + "\n" }
            s += "--- last \(logTail) log lines ---\n"
            s += snap.recentLines.suffix(logTail).map { redact($0) }.joined(separator: "\n")
            s += "\n"
        }
        s += "```\n"
        return s
    }

    /// Hides most of the ECID (a unique hardware identifier) before sharing.
    public static func redact(_ line: String) -> String {
        var out = line
        let patterns = [#"(ECID:[0-9A-Fa-f]{6})[0-9A-Fa-f]+"#, #"(0x[0-9A-Fa-f]{4})[0-9A-Fa-f]{8,12}"#, #"(UniqueChipID: )\d+"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1…")
            }
        }
        return out
    }
}
