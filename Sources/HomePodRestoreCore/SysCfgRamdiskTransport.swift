import Foundation

// MARK: - SSH-ramdisk transport (hardware path)
//
// Talks to SysCfg on a pod that is ALREADY booted into a shell-capable
// ssh-ramdisk. Booting that ramdisk is a separate step (gaster pwn + ra1nsn0w,
// analogous to RestoreJob's boot test but with the ssh ramdisk image) and is
// left to a future RamdiskBooter — this type assumes the SSH endpoint is up,
// typically a usbmux-forwarded local port.
//
// Wire format, and why:
// ProcessRunner streams combined stdout/stderr as text and gives the child no
// stdin. So we move the (small, ~hundreds of bytes to a few KB) SysCfg blob as
// base64 wrapped in explicit markers, which survives SSH banners and any stderr
// noise, and for the write we pass the base64 as a command argument rather than
// piping stdin.
//
// WRITE PATH — now a WriteSink, not a bare command string:
// The read path is proven. The write path is still being validated, and there is
// more than one candidate mechanism (AppleEffaceableStorage SetLocker is primary;
// a DIAGS kext is the fallback — see WriteSink.swift and SYSCFG_WRITE_FINDINGS.md).
// The transport therefore no longer hard-codes HOW a write happens. It owns only
// the generic plumbing — "stage a file on the pod, run a tool" — and delegates the
// actual commit to the configured `WriteSink`, which carries its own validation
// state. A legacy `sinkCommand` string path is retained for the pre-WriteSink
// `base64 | tool` shape and for tests, but when a `writeSink` is set it wins.
//
// TO CONFIRM ON FIRST HARDWARE RUN (the de-risk read provides these):
//   • dumpCommand  — how the booted ramdisk emits the live SysCfg blob. Two
//                    documented candidates: the Diags `syscfg` console command,
//                    or reading AppleDiagnosticDataSysCfg out of the IORegistry.
//   • the WriteSink's confirmed type_id / validation — proven read-only first via
//     the GetLocker probe, then a same-bytes round-trip, before any real write.

// MARK: - Pod-side ioreg (shared rules)
//
// Every ioreg command the Mac side sends to a pod is built here, so three rules
// hold everywhere:
//
//   1. NEVER a bare `ioreg -l`. Dumping the whole registry WITH properties makes
//      the ramdisk serialise every driver's properties and kernel-panics the
//      pod. Only targeted `ioreg -r -c <ClassName> [-l]` queries are allowed
//      (without `-l` a query prints node names only and reads no property).
//   2. ANSI colour is always stripped. This ramdisk's ioreg colourizes its
//      output even into a pipe (`ESC[0;31m99 … ESC[0;0m`), which breaks every
//      numeric / string match downstream. ESC is produced with printf because
//      the ramdisk's BSD sed has no `\x1b`.
//   3. PATH is set explicitly — ioreg is not on dropbear's non-interactive PATH.
//
// The `hpdiag-*` overlay scripts follow the same rules with their own `ior`
// wrapper; this is the Swift-side twin.
public enum RamdiskIOReg {
    /// Directories searched on the pod.
    public static let searchPath = "/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin:/usr/local/sbin"

    /// Shell prelude: sets PATH and defines `hpior`, an ioreg wrapper with
    /// `-w 0` (no line truncation, so long data blobs survive) whose output has
    /// the ANSI colour escapes removed. Falls back to plain ioreg if the ramdisk
    /// has no sed, so the proven SysCfg read never depends on it (the Mac side
    /// strips ANSI again when it parses).
    public static let prelude: String =
        "PATH=" + searchPath + "; export PATH; "
        + #"E=$(printf '\033'); "#
        + #"hpior() { if command -v sed >/dev/null 2>&1; then ioreg -w 0 "$@" 2>/dev/null | sed -e "s/$E\[[0-9;]*m//g"; else ioreg -w 0 "$@" 2>/dev/null; fi; }; "#

    /// Only plain class names are ever spliced into a pod-side command.
    public static func isSafeClassName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 96 else { return false }
        return name.unicodeScalars.allSatisfy { c in
            (c.value >= 48 && c.value <= 57) || (c.value >= 65 && c.value <= 90)
                || (c.value >= 97 && c.value <= 122) || c == "_"
        }
    }

    /// One targeted query, for use after `prelude`: `hpior -r [-d 1] -c <Class> [-l]`.
    /// - Parameters:
    ///   - properties: `false` prints node names only (no property is read).
    ///   - nodeOnly: `true` limits the query to the matching node itself, not
    ///     its children.
    /// Returns nil for anything that isn't a plain class name.
    public static func query(forClass name: String, properties: Bool = true, nodeOnly: Bool = false) -> String? {
        guard isSafeClassName(name) else { return nil }
        return "hpior -r" + (nodeOnly ? " -d 1" : "") + " -c " + name + (properties ? " -l" : "")
    }

    /// A complete pod-side command line: the prelude, then `body`.
    public static func command(_ body: String) -> String { prelude + body }
}

public struct SSHRamdiskTransport: SysCfgTransport, RamdiskShell {
    public struct Config: Sendable {
        /// Reads the SysCfg blob out of the IORegistry with a targeted query
        /// (never a full `ioreg -l` — see `RamdiskIOReg`).
        ///
        /// Stock SSH ramdisk: the node is `AppleDiagnosticDataAccessReadOnly`.
        /// DIAGS kernelcache boot: the writable `AppleDiagnosticDataAccess` kext
        /// takes its place, so that class is queried when the read-only one
        /// isn't there. The presence test is names-only and uses shell builtins.
        public static let defaultDumpCommand = RamdiskIOReg.command(
            "n=$(hpior -r -c AppleDiagnosticDataAccessReadOnly); "
            + "if [ -n \"$n\" ]; then hpior -r -c AppleDiagnosticDataAccessReadOnly -l; "
            + "else hpior -r -c AppleDiagnosticDataAccess -l; fi")

        public var sshTool: URL
        /// sshpass, for dropbear's password auth (password below). Optional: if
        /// nil, plain ssh is used (key-based or interactive).
        public var sshpass: URL?
        public var password: String
        public var host: String
        public var port: Int
        public var user: String
        /// Extra ssh flags (host-key checking off for the ephemeral ramdisk, etc.).
        public var sshOptions: [String]
        /// Pod-side command whose output carries the SysCfg data. For HomePod
        /// this is an ioreg query; the blob is the `sysCfgProperty` value.
        public var dumpCommand: String
        /// When set, dumpCommand is treated as ioreg output and this IORegistry
        /// data property is extracted as the SysCfg blob (the documented read
        /// path: AppleDiagnosticDataSysCfg). nil = treat dumpCommand output as a
        /// raw base64 stream instead.
        public var sysCfgProperty: String?
        /// LEGACY pod-side sink that reads a raw SysCfg blob on stdin and writes it
        /// to NAND. PLACEHOLDER — confirm before any write. Superseded by
        /// `writeSink`; retained for the old `base64 | tool` shape and for tests.
        public var sinkCommand: String
        /// The validated write mechanism. When set, `writeRawBlob` delegates the
        /// commit to this sink (stage → sink.commit). nil → legacy `sinkCommand`.
        public var writeSink: (any WriteSink)?
        /// Where blobs are staged on the pod before a sink tool reads them.
        public var stageRemotePath: String
        public var timeout: TimeInterval

        public init(sshTool: URL,
                    sshpass: URL? = nil,
                    password: String = "alpine",
                    host: String = "127.0.0.1",
                    port: Int = 2222,
                    user: String = "root",
                    sshOptions: [String] = ["-o", "StrictHostKeyChecking=no",
                                            "-o", "UserKnownHostsFile=/dev/null",
                                            "-o", "LogLevel=ERROR"],
                    dumpCommand: String = Config.defaultDumpCommand,
                    sysCfgProperty: String? = "AppleDiagnosticDataSysCfg",
                    sinkCommand: String = "syscfg_write",     // legacy write path: TO CONFIRM
                    writeSink: (any WriteSink)? = nil,
                    stageRemotePath: String = "/tmp/syscfg.bin",
                    timeout: TimeInterval = 30) {
            self.sshTool = sshTool
            self.sshpass = sshpass
            self.password = password
            self.host = host
            self.port = port
            self.user = user
            self.sshOptions = sshOptions
            self.dumpCommand = dumpCommand
            self.sysCfgProperty = sysCfgProperty
            self.sinkCommand = sinkCommand
            self.writeSink = writeSink
            self.stageRemotePath = stageRemotePath
            self.timeout = timeout
        }
    }

    static let beginMarker = "===SYSCFG_B64_BEGIN==="
    static let endMarker = "===SYSCFG_B64_END==="

    public let config: Config

    public init(config: Config) { self.config = config }

    public func readRawBlob() async throws -> Data {
        // HomePod: dumpCommand is an ioreg query; the SysCfg blob is the
        // `sysCfgProperty` data value in its output (the documented read path).
        if let prop = config.sysCfgProperty {
            let out = try await runSSH(config.dumpCommand)
            guard let blob = Self.extractIORegHexProperty(prop, from: out), !blob.isEmpty else {
                throw SysCfgError.transportUnavailable("Couldn't find \(prop) in the ioreg output — the diagnostics node may not be present on this ramdisk.")
            }
            return blob
        }
        // Generic path: wrap the pod-side dump in markers + base64 so we can
        // recover exact bytes from line-oriented, banner-polluted SSH output.
        let remote = "echo \(Self.beginMarker); \(config.dumpCommand) | base64; echo \(Self.endMarker)"
        let out = try await runSSH(remote)
        guard let b64 = Self.extractBetweenMarkers(out) else {
            throw SysCfgError.transportUnavailable("Couldn't find the SysCfg payload in the ramdisk's response. Dump command may be wrong — see dumpCommand.")
        }
        guard let data = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")), !data.isEmpty else {
            throw SysCfgError.emptyDump
        }
        return data
    }

    /// Extract an IORegistry data property value `"<name>" = <hex…>` from
    /// targeted `ioreg -r -c <Class> -l` text, returning the decoded bytes. ANSI
    /// colour is stripped here too, in case the pod-side strip didn't run.
    static func extractIORegHexProperty(_ name: String, from text: String) -> Data? {
        let clean = stripAnsi(text)
        guard let r = clean.range(of: "\"\(name)\"") else { return nil }
        let rest = clean[r.upperBound...]
        guard let lt = rest.firstIndex(of: "<"),
              let gt = rest[rest.index(after: lt)...].firstIndex(of: ">") else { return nil }
        let hex = rest[rest.index(after: lt)..<gt].filter { $0.isHexDigit }
        let data = hexToData(String(hex))
        return data.isEmpty ? nil : data
    }

    /// Remove ANSI CSI escape sequences (ESC [ … letter).
    static func stripAnsi(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{1B}" {
                var j = s.index(after: i)
                while j < s.endIndex, !(s[j].isLetter) { j = s.index(after: j) }
                if j < s.endIndex { j = s.index(after: j) }
                i = j
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
    }

    static func hexToData(_ hex: String) -> Data {
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if i < n, let b = UInt8(hex[i..<n], radix: 16) { d.append(b) }
            i = n
        }
        return d
    }

    /// Whether this transport has a write mechanism it's allowed to use. Prefers
    /// the structured `writeSink.isValidated` gate; falls back to the legacy
    /// "sink string isn't the placeholder" check. A sink string that doesn't name
    /// a validated write mechanism — the legacy placeholder, empty, or whitespace —
    /// must never touch NAND.
    public var hasValidatedSink: Bool {
        if let sink = config.writeSink { return sink.isValidated }
        let s = config.sinkCommand.trimmingCharacters(in: .whitespaces)
        return !s.isEmpty && s != "syscfg_write"
    }

    public func writeRawBlob(_ data: Data) async throws {
        guard hasValidatedSink else {
            throw SysCfgError.transportUnavailable("The SysCfg write mechanism isn't validated yet. The read path is proven, but the write path (the \"sink\") still has to be confirmed on a pod before any write — refusing to guess. Run the GetLocker probe (Pull diagnostics), confirm the SysCfg type_id, pass a same-bytes round-trip, then enable the sink.")
        }
        // Preferred path: a structured WriteSink. Delegate the commit to it — it
        // stages the blob (chunked, ARG_MAX-safe) and drives its on-device tool.
        if let sink = config.writeSink {
            try await sink.commit(blob: data, via: self)
            return
        }
        // Legacy path: pass the blob as base64 on the command line (small payload)
        // and decode on the pod into the sink. No reliance on child stdin.
        let b64 = data.base64EncodedString()
        let remote = "echo \(shellQuote(b64)) | base64 -d | \(config.sinkCommand)"
        _ = try await runSSH(remote)
    }

    // MARK: - File staging / tool running (the generic write plumbing)
    //
    // Real sinks are "stage a file + run a tool", not a stdin pipe. These two
    // methods are that mechanism, exposed on the transport so a sink (which is
    // handed a RamdiskShell) and tests can both drive it. The chunked, size-
    // verified staging lives on the RamdiskShell extension in WriteSink.swift, so
    // there's exactly one correct copy; these are thin, well-named entry points.

    /// Stage `data` to `remotePath` on the pod (chunked base64, size-verified).
    public func stageFile(data: Data, remotePath: String) async throws {
        try await stage(data, at: remotePath)
    }

    /// Run a pod-side sink tool and return its combined output. Identical to
    /// `run`, but named for intent at the call site.
    @discardableResult
    public func runSinkTool(command: String) async throws -> String {
        try await run(command)
    }

    /// Read-only: enumerate what the booted ramdisk offers for writing SysCfg, so
    /// the sink can be pinned without guessing. Looks for the write-side IORegistry
    /// node and any candidate CLI tools. Never writes anything.
    ///
    /// What a real pod showed (stock ramdisk): the effaceable store is ~960 bytes
    /// — far too small for the 128 KB SysCfg — and SysCfg is served by
    /// `AppleDiagnosticDataAccessReadOnly` on top of `AppleNANDConfigAccess`. The
    /// write path is therefore the DIAGS kernelcache's writable
    /// `AppleDiagnosticDataAccess` kext plus `/diags/syscfg_write`, so both are
    /// reported here. All queries are targeted and ANSI-stripped (`RamdiskIOReg`).
    public static let writeProbeCommand = RamdiskIOReg.command([
        "echo '== AppleEffaceableStorage (SetLocker) =='",
        "hpior -r -c AppleEffaceableStorage -l | head -40",
        "echo '== AppleEffaceableStorageUserClient matchable =='",
        "hpior -r -c AppleEffaceableStorageUserClient | head -10",
        "echo '== AppleNANDConfigAccess (SysCfg provider) =='",
        "hpior -r -c AppleNANDConfigAccess -l | head -20",
        "echo '== AppleDiagnosticDataAccess (writable kext - DIAGS kernelcache only) =='",
        "hpior -r -c AppleDiagnosticDataAccess | head -10",
        "echo '== DIAGS writer (/diags/syscfg_write) =='",
        "if [ -x /diags/syscfg_write ]; then echo present; else echo 'not present'; fi",
        "echo '== syscfg-probe / overlay tools =='",
        "for t in syscfg-probe hpdiag-getlocker syscfg nvram nand_sysconfig; do command -v $t 2>/dev/null; done",
        "echo '== /usr/local/bin =='",
        "ls -1 /usr/local/bin 2>/dev/null",
        "echo '== done =='",
    ].joined(separator: "; "))

    public func probeWriteFacilities() async throws -> String {
        try await run(Self.writeProbeCommand)
    }

    /// Run the configured write sink's READ-ONLY probe (GetLocker discovery).
    /// Returns nil when no sink is configured. Zero write risk.
    public func probeSink() async throws -> ProbeResult? {
        guard let sink = config.writeSink else { return nil }
        return try await sink.probe(via: self)
    }

    // MARK: - RamdiskShell (generic pod-side commands)

    /// Run a pod-side command, returning combined text output.
    public func run(_ command: String) async throws -> String {
        try await runSSH(command)
    }

    /// Run a pod-side command whose stdout is binary; returns exact bytes.
    /// Wrapped in markers + base64 so it survives SSH banners and stderr noise.
    public func dumpBinary(_ command: String) async throws -> Data {
        let remote = "echo \(Self.beginMarker); { \(command); } | base64; echo \(Self.endMarker)"
        let out = try await runSSH(remote)
        guard let b64 = Self.extractBetweenMarkers(out) else {
            throw SysCfgError.transportUnavailable("Couldn't find the payload markers in the pod's response.")
        }
        let cleaned = b64.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard let data = Data(base64Encoded: cleaned) else {
            throw SysCfgError.transportUnavailable("The pod's base64 payload didn't decode.")
        }
        return data
    }

    // MARK: - SSH plumbing

    private func runSSH(_ remoteCommand: String) async throws -> String {
        var sshArgs = config.sshOptions
        sshArgs += ["-p", String(config.port), "\(config.user)@\(config.host)", remoteCommand]
        // dropbear on the ramdisk uses password auth; drive it with sshpass.
        let executable: URL
        let args: [String]
        if let sp = config.sshpass {
            executable = sp
            args = ["-p", config.password, config.sshTool.path] + sshArgs
        } else {
            executable = config.sshTool
            args = sshArgs
        }
        let runner = ProcessRunner(executable: executable, arguments: args,
                                   environment: ToolEnvironment.standard)
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(config.timeout * 1_000_000_000))
            runner.cancel()
        }
        let result = try await runner.run(onLine: { _ in })
        timer.cancel()
        if result.wasCancelled {
            throw SysCfgError.transportUnavailable("SSH to the ramdisk timed out after \(Int(config.timeout))s.")
        }
        if result.exitCode != 0 {
            throw SysCfgError.transportUnavailable(Self.failureMessage(exitCode: result.exitCode,
                                                                       output: result.output, port: config.port))
        }
        return result.output
    }

    /// Why a command didn't succeed, with what the pod (or ssh) printed.
    ///
    /// ssh itself exits 255 when it can't connect or authenticate; any other
    /// status is the POD-SIDE command's own, relayed — the connection was fine.
    /// Telling the two apart (and keeping the output) is what makes a failure
    /// diagnosable: "exit 127 … base64: command not found" is a missing tool,
    /// not a dead link.
    static func failureMessage(exitCode: Int32, output: String, port: Int) -> String {
        let lines = stripAnsi(output)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = String(lines.suffix(3).joined(separator: " / ").suffix(300))
        let said = tail.isEmpty ? "" : " Output: \(tail)"
        if exitCode == 255 {
            return "SSH to the ramdisk failed (exit 255). Is the pod booted into the ssh-ramdisk and port \(port) forwarded?" + said
        }
        if exitCode == 127 {
            return "The pod ran the command, but a tool it needs isn't on this ramdisk (exit 127)." + said
        }
        return "The command failed on the pod (exit \(exitCode)); the SSH connection itself worked." + said
    }

    static func extractBetweenMarkers(_ text: String) -> String? {
        guard let a = text.range(of: beginMarker), let b = text.range(of: endMarker),
              a.upperBound <= b.lowerBound else { return nil }
        let inner = text[a.upperBound..<b.lowerBound]
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
