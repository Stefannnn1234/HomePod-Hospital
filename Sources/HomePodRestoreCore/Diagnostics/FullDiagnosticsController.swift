import Foundation

// MARK: - Full diagnostics ("Intake Report")
//
// Boots the ssh-ramdisk ONCE and runs every `hpdiag-*` tool back to back,
// assembling one report keyed to the pod's serial. Same boot-once-then-probe
// structure as `DiagnosticsController.pull`, same plumbing (`RamdiskShell.run`),
// and — like that pull — read-only as far as the pod's storage goes.
//
// The one thing written is the scripts themselves: a ramdisk built before a
// script existed doesn't carry it, so the scripts the app was given are pushed
// into the ramdisk's tmpfs (`DiagCommands.pushDirectory`) first. That is RAM
// only — nothing on NAND is touched, and it is gone on reboot.
//
// One tool failing never sinks the run: a script that is missing, times out or
// prints something unreadable becomes a "couldn't check" entry in the report,
// and the remaining tools still run.

public final class FullDiagnosticsController: @unchecked Sendable {
    let booter: RamdiskBooter
    /// Tools to run, in order.
    public var tools: [DiagTool]
    /// The `hpdiag-*` scripts the app carries, pushed to the pod when its
    /// ramdisk doesn't have them. Empty = rely on the ramdisk alone.
    public var scripts: [DiagScript]

    public init(booter: RamdiskBooter, tools: [DiagTool] = DiagTool.allCases, scripts: [DiagScript] = []) {
        self.booter = booter
        self.tools = tools
        self.scripts = scripts
    }

    public enum Outcome: Sendable {
        case ok(FullDiagnosticsReport)
        case failed(String)
    }

    /// Per-tool progress, reported when a tool starts and again when it ends.
    public struct Progress: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case running
            case finished(DiagVerdict)
            /// The tool produced no result; the message says why.
            case failed(String)
        }

        public let tool: DiagTool
        /// Zero-based position of `tool` in the run.
        public let index: Int
        public let total: Int
        public let state: State

        public init(tool: DiagTool, index: Int, total: Int, state: State) {
            self.tool = tool
            self.index = index
            self.total = total
            self.state = state
        }

        /// Tools finished so far.
        public var completed: Int { state == .running ? index : index + 1 }
        /// 0…1, for a progress bar.
        public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    /// Boot the pod (per the booter), run every tool, tear down.
    public func run(ecid: UInt64,
                    onPhase: @escaping @Sendable (SysCfgPhase) -> Void = { _ in },
                    onLog: @escaping @Sendable (String) -> Void = { _ in },
                    onProgress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Outcome {
        onPhase(.unlocking)
        let pod: BootedPod
        do {
            onPhase(.bootingRamdisk)
            pod = try await booter.boot(ecid: ecid, onLog: onLog)
        } catch {
            return .failed(error.localizedDescription)
        }
        defer { Task { await pod.teardown() } }

        onPhase(.working)
        let outcome = await Self.run(on: pod, tools: tools, scripts: scripts, onLog: onLog, onProgress: onProgress)
        onPhase(.done)
        return outcome
    }

    /// Run the tools on a pod that is already booted. Does not tear the pod
    /// down — whoever booted it owns that.
    public static func run(on pod: BootedPod,
                           tools: [DiagTool] = DiagTool.allCases,
                           scripts: [DiagScript] = [],
                           onLog: @escaping @Sendable (String) -> Void = { _ in },
                           onProgress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Outcome {
        guard let shell = pod.shell else {
            return .failed("This booter doesn't expose a shell to run diagnostics.")
        }

        // Identify the unit first, through the proven SysCfg read. Best-effort:
        // a blank chip has no serial, and that is itself a finding the factory
        // tool reports — so a failure here is only logged.
        var sysCfg: SysCfgData?
        onLog("identifying the unit (SysCfg read)…")
        do {
            let blob = try await pod.transport.readRawBlob()
            let parsed = SysCfgParser.parse(blob)
            sysCfg = parsed
            onLog("serial \(parsed.serialNumber ?? "not found").")
        } catch {
            onLog("couldn't read SysCfg for the serial: \(error.localizedDescription)")
        }

        // Make sure the scripts are there before anything tries to run them.
        // Never fatal: if the push fails, the tools below report "couldn't
        // check" exactly as they would on a ramdisk without the scripts.
        var pushFailure: String?
        if !scripts.isEmpty {
            if Task.isCancelled { return .failed("Diagnostics were cancelled.") }
            if case .failed(_, let message) = await pushDiagnosticScripts(scripts, via: shell, onLog: onLog) {
                pushFailure = message
            }
        }

        var results: [DiagToolResult] = []
        var failures: [DiagParseError?] = []
        for (index, tool) in tools.enumerated() {
            if Task.isCancelled { return .failed("Diagnostics were cancelled.") }
            onProgress(Progress(tool: tool, index: index, total: tools.count, state: .running))
            onLog("running \(DiagCommands.script(for: tool)) (\(tool.title))…")

            var output: String?
            do {
                let text = try await shell.run(DiagCommands.invocation(for: tool))
                output = text
                let result = try DiagParsers.parse(tool, output: text)
                results.append(result)
                onLog("\(tool.title): \(result.verdict.tag).")
                onProgress(Progress(tool: tool, index: index, total: tools.count, state: .finished(result.verdict)))
            } catch {
                let message = error.localizedDescription
                failures.append(error as? DiagParseError)
                results.append(.failed(DiagToolFailure(tool: tool, message: message,
                                                       rawOutput: output.map { String($0.suffix(2000)) })))
                onLog("\(tool.title): couldn't check — \(message)")
                onProgress(Progress(tool: tool, index: index, total: tools.count, state: .failed(message)))
            }
        }

        // Nothing at all came back: say why instead of showing an empty report.
        if !tools.isEmpty, failures.count == tools.count {
            if failures.allSatisfy({ $0 == .toolMissing }) {
                if let pushFailure {
                    return .failed("This ramdisk doesn't include the diagnostic scripts (hpdiag-*), and copying them to the pod failed: \(pushFailure)")
                }
                return .failed("This ramdisk doesn't include the diagnostic scripts (hpdiag-*). Rebuild the SSH ramdisk with the current overlay, boot it, then run diagnostics again.")
            }
            if case .failed(let first)? = results.first {
                return .failed("None of the checks returned a result. First error: \(first.message)")
            }
        }

        let serial = Self.serial(from: results) ?? sysCfg?.serialNumber
        let report = FullDiagnosticsReport(serial: serial, timestamp: Date(),
                                           results: Self.finalize(results, sysCfg: sysCfg))
        onLog("diagnostics finished — overall \(report.overall.tag).")
        return .ok(report)
    }

    // MARK: - Script push

    /// What `pushDiagnosticScripts` did.
    public enum ScriptPush: Sendable, Equatable {
        /// There was nothing to push (no usable scripts were supplied).
        case notNeeded
        /// An earlier run on this boot already pushed this exact set.
        case alreadyPushed
        /// These scripts were written to one of `DiagCommands.pushDirectories`.
        case pushed([String])
        /// The push didn't complete. `pushed` lists what did land.
        case failed(pushed: [String], message: String)
    }

    /// How many times one script is tried before the push gives up.
    static let pushAttempts = 2
    /// Pause before a second attempt.
    static let pushRetryDelay: UInt64 = 1_000_000_000

    /// Write one script to the pod and check that every byte arrived.
    static func pushOne(_ script: DiagScript, into directory: String, via shell: RamdiskShell) async throws {
        var out = ""
        for command in DiagCommands.scriptPushCommands(name: script.name, content: script.content, directory: directory) {
            out = try await shell.run(command)
        }
        guard let size = pushedSize(in: out) else {
            let tail = out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            throw SysCfgError.transportUnavailable("the pod didn't confirm the write" + (tail.isEmpty ? "." : ": \(tail)"))
        }
        guard size == script.content.count else {
            throw SysCfgError.transportUnavailable("\(size) of \(script.content.count) bytes arrived")
        }
    }

    /// Make the `hpdiag-*` scripts available on the pod, once per run.
    ///
    /// Asks the pod (one read-only command) which scripts its ramdisk already
    /// carries and what an earlier run pushed. Every script the app has is then
    /// written to `DiagCommands.pushDirectory` — including ones the ramdisk
    /// bakes in, because a baked-in copy may be a stale revision and the pushed
    /// directory is first on PATH. Each is written to the
    /// tmpfs as `printf '<escaped bytes>' > file && chmod 755 file` (the
    /// ramdisk has no base64 to decode with), its byte count is checked, and
    /// a script that fails is tried once more. A stamp records what was pushed, so a repeat run
    /// on the same boot costs one command — and a run with CHANGED scripts
    /// pushes again instead of using the stale copies.
    ///
    /// Never throws: a failure is logged and returned, and the caller carries
    /// on (the affected tools then report that they are missing).
    @discardableResult
    public static func pushDiagnosticScripts(_ scripts: [DiagScript],
                                             via shell: RamdiskShell,
                                             onLog: @escaping @Sendable (String) -> Void = { _ in }) async -> ScriptPush {
        let usable = scripts.filter { $0.hasSafeName && !$0.content.isEmpty }
        for skipped in scripts where !(skipped.hasSafeName && !skipped.content.isEmpty) {
            onLog("not pushing \"\(skipped.name)\" — \(skipped.content.isEmpty ? "it is empty" : "unexpected file name").")
        }
        guard !usable.isEmpty else { return .notNeeded }

        // 1. What does the ramdisk have, and what did an earlier run push?
        let check: String
        do {
            check = try await shell.run(DiagCommands.scriptCheck(names: usable.map(\.name)))
        } catch {
            let message = "couldn't check which diagnostic scripts the pod has: \(error.localizedDescription)"
            onLog(message)
            return .failed(pushed: [], message: message)
        }
        var present = Set<String>()
        var stamp = ""
        var lacking: [String] = []
        var directory = ""
        var remounted = false
        for raw in check.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(DiagCommands.haveMarkerPrefix) {
                present.insert(String(line.dropFirst(DiagCommands.haveMarkerPrefix.count)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix(DiagCommands.stampMarkerPrefix) {
                stamp = String(line.dropFirst(DiagCommands.stampMarkerPrefix.count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix(DiagCommands.dirMarkerPrefix) {
                directory = String(line.dropFirst(DiagCommands.dirMarkerPrefix.count)).trimmingCharacters(in: .whitespaces)
            } else if line == DiagCommands.remountMarker {
                remounted = true
            } else if line.hasPrefix(DiagCommands.lackMarkerPrefix) {
                lacking.append(String(line.dropFirst(DiagCommands.lackMarkerPrefix.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !lacking.isEmpty {
            onLog("this ramdisk has no \(lacking.joined(separator: ", ")) — the diagnostic scripts use \(lacking.count == 1 ? "it" : "them"), so checks can fail or come back incomplete until the SSH ramdisk is rebuilt with \(lacking.count == 1 ? "that tool" : "those tools").")
        }

        // The app's copies are authoritative: push all of them, even when the
        // ramdisk has its own. A ramdisk built earlier can carry a stale
        // revision (early ones ran a full `ioreg -l`, which panics the pod), and
        // `DiagCommands.path` puts the pushed directory first so these win.
        let missing = usable
        if !present.isEmpty {
            onLog("this ramdisk has \(present.count) built-in diagnostic script\(present.count == 1 ? "" : "s"); the app's current copies are used instead.")
        }
        let wanted = fingerprint(of: missing)
        if stamp == wanted {
            onLog("diagnostic scripts are already on the pod from an earlier run.")
            return .alreadyPushed
        }

        // Only a directory we offered is ever spliced into a command.
        guard DiagCommands.pushDirectories.contains(directory) else {
            let message = "couldn't find anywhere writable on the pod for the diagnostic scripts (tried \(DiagCommands.pushDirectories.joined(separator: ", ")))."
            onLog(message)
            return .failed(pushed: [], message: message)
        }
        if remounted {
            onLog("the ramdisk's root was read-only — remounted it read-write (RAM only, NAND untouched) to make room for the scripts.")
        }

        // 2. Push what's missing, one script per command.
        onLog("copying \(missing.count) diagnostic script\(missing.count == 1 ? "" : "s") to the pod (\(directory))…")
        var pushed: [String] = []
        for script in missing {
            if Task.isCancelled {
                return .failed(pushed: pushed, message: "cancelled while copying the diagnostic scripts.")
            }
            // Each attempt rewrites the file from its first byte, so trying
            // again after a dropped connection or a short write is safe.
            var failure: String?
            for attempt in 1...pushAttempts {
                do {
                    try await pushOne(script, into: directory, via: shell)
                    failure = nil
                    break
                } catch {
                    failure = error.localizedDescription
                    if attempt < pushAttempts, !Task.isCancelled {
                        onLog("copying \(script.name) failed (\(error.localizedDescription)) — trying again…")
                        try? await Task.sleep(nanoseconds: pushRetryDelay)
                    }
                }
            }
            if let failure {
                let message = "couldn't copy \(script.name) to the pod: \(failure)"
                onLog(message)
                return .failed(pushed: pushed, message: message)
            }
            pushed.append(script.name)
        }

        // 3. Remember this set. Best-effort — without the stamp the next run
        // simply pushes again.
        _ = try? await shell.run(DiagCommands.scriptStamp(wanted, directory: directory))
        onLog("copied \(pushed.count) diagnostic script\(pushed.count == 1 ? "" : "s").")
        return .pushed(pushed)
    }

    /// Byte count from the last `HPDIAG_PUSHED <n>` line, if there is one.
    static func pushedSize(in output: String) -> Int? {
        for raw in output.components(separatedBy: .newlines).reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(DiagCommands.pushedMarkerPrefix) else { continue }
            return Int(line.dropFirst(DiagCommands.pushedMarkerPrefix.count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Stable fingerprint (FNV-1a 64) of a set of scripts — names and bytes,
    /// independent of order. Only used to tell "same scripts as last push"
    /// from "changed"; not a security measure.
    static func fingerprint(of scripts: [DiagScript]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for script in scripts.sorted(by: { $0.name < $1.name }) {
            for byte in script.name.utf8 { hash = (hash ^ UInt64(byte)) &* prime }
            hash = (hash ^ 0x00) &* prime
            for byte in script.content { hash = (hash ^ UInt64(byte)) &* prime }
            hash = (hash ^ 0xff) &* prime
        }
        return String(hash, radix: 16)
    }

    /// Serial as reported by the factory tool, if it gave one.
    static func serial(from results: [DiagToolResult]) -> String? {
        for r in results {
            if case .factory(let f) = r, let s = f.serial { return s }
        }
        return nil
    }

    /// Post-processing on the Mac: fold mic + accel into one sensors entry, and
    /// compare the radios' MACs against SysCfg when the script didn't.
    static func finalize(_ results: [DiagToolResult], sysCfg: SysCfgData?) -> [DiagToolResult] {
        FullDiagnosticsReport.mergingSensors(results).map { result in
            guard case .radio(let radio) = result, let sysCfg else { return result }
            return .radio(radio.crossChecked(wifiMAC: sysCfg.wifiMAC, bluetoothMAC: sysCfg.bluetoothMAC))
        }
    }
}
