import Foundation

// MARK: - Firmware pinning
//
// The SSH ramdisk, the SysCfg write RE, and the shipping restore IPSW must all
// agree on ONE audioOS version, and that version is 18.3 (build 22K557) — NOT the
// 17.5 the SSHRD create step used to default to.
//
// Why 18.3 is pinned:
//   1. The authoritative write RE (SYSCFG_WRITE_FINDINGS.md) was done against the
//      18.3 / 22K557 kernelcache. Every address, selector index (GetLocker = 5,
//      SetLocker = 6), gate (`clientHasPrivilege("SecureRoot")`), and the
//      AppleEffaceableStorageUserClient dispatch table were resolved in THAT
//      build. Booting a 17.5 ramdisk to drive a write validated on 18.3 means the
//      on-device kernel doesn't match the RE — selectors, offsets, and the locker
//      class model can all differ silently. That is exactly the "guessing at
//      silicon" posture the write gate exists to prevent.
//   2. The restore IPSW the app actually ships / restores is 18.3. Pinning the
//      ramdisk to the same build keeps the booted environment, the restore
//      environment, and the RE on a single version, so a validated write path
//      stays valid end to end.
//   3. Validation is build-specific (see WriteSinkValidation.lastValidatedBuild).
//      A single pinned build lets us invalidate cleanly when Apple ships a new one,
//      instead of carrying a fuzzy mix of 17.5 boots and 18.3 writes.
//
// Anything that builds or boots the SSH ramdisk, or records a sink validation,
// should read its default version from here rather than hard-coding a string.
public enum RamdiskFirmware {
    /// The pinned audioOS version for SSH-ramdisk builds/boots and write RE.
    public static let pinnedVersion = "18.3"
    /// The pinned build the write RE and validations are keyed to.
    public static let pinnedBuild = "22K557"
}

/// UI-facing phases of a SysCfg operation.
public enum SysCfgPhase: Int, Sendable, Comparable {
    case unlocking, bootingRamdisk, connecting, working, verifying, done
    public static func < (a: SysCfgPhase, b: SysCfgPhase) -> Bool { a.rawValue < b.rawValue }
    public var title: String {
        switch self {
        case .unlocking: return "Unlocking (checkm8)"
        case .bootingRamdisk: return "Booting the SSH ramdisk"
        case .connecting: return "Connecting to the pod"
        case .working: return "Talking to SysCfg"
        case .verifying: return "Verifying"
        case .done: return "Done"
        }
    }
}

/// A pod booted into the SSH ramdisk: a transport to talk to it, and a teardown
/// to release the port-forward / boot resources when finished.
public struct BootedPod: Sendable {
    public let transport: SysCfgTransport
    /// Optional raw shell for features beyond SysCfg (panic-log/ioreg pull).
    public let shell: RamdiskShell?
    public let teardown: @Sendable () async -> Void
    public init(transport: SysCfgTransport, shell: RamdiskShell? = nil,
                teardown: @escaping @Sendable () async -> Void) {
        self.transport = transport
        self.shell = shell
        self.teardown = teardown
    }
}

/// Unlocks a pod and boots it into a shell-capable ramdisk.
public protocol RamdiskBooter: Sendable {
    func boot(ecid: UInt64, onLog: @escaping @Sendable (String) -> Void) async throws -> BootedPod
}

// MARK: - Fake booter (tests + dry runs)

/// Hands back a preset transport without touching hardware.
public struct FakeRamdiskBooter: RamdiskBooter {
    let transport: SysCfgTransport
    public init(transport: SysCfgTransport) { self.transport = transport }
    public func boot(ecid: UInt64, onLog: @escaping @Sendable (String) -> Void) async throws -> BootedPod {
        onLog("[fake] booted ssh-ramdisk for \(String(format: "0x%016llX", ecid))")
        return BootedPod(transport: transport, teardown: {})
    }
}

// MARK: - Real booter (hardware)
//
// Faithful to the boot flow tihmstar / david / Nic used for AudioAccessory1,1
// (captured from the HomePod repair chat):
//   gaster pwn + reset  →  APTicket (irecovery nonce → tsschecker)  →
//   ra1nsn0w boots the custom ramdisk  →  iproxy forwards SSH to localhost.
// dropbear from the overlay answers on :22 as root / password "alpine".
//
// The only piece still unproven for SysCfg specifically is the pod-side WRITE
// mechanism, now modeled as a WriteSink (primary: AppleEffaceableStorage
// SetLocker). The read path (`dumpCommand`) is proven.
public struct GasterRamdiskBooter: RamdiskBooter {
    public struct Config: Sendable {
        public var gaster: URL
        public var ra1nsn0w: URL?
        public var irecovery: URL?
        public var tsschecker: URL?
        public var forwarder: URL?          // iproxy
        public var sshTool: URL
        public var sshpass: URL?            // password auth for dropbear
        public var ramdisk: URL             // built ssh-ramdisk .img4
        public var buildManifest: URL?      // HomePod BuildManifest.plist (for the APTicket)
        public var firmwareIPSW: URL?       // fallback: extract BuildManifest from this .ipsw
        public var genericTicket: URL?      // shipped per-chip shsh (checkm8 needs no live ticket)
        public var deviceIdentifier: String
        public var localPort: Int
        public var gasterTargetsECID: Bool
        // Confirmed ra1nsn0w flags + boot-args.
        public var ra1nsn0wFlags: [String]
        public var bootArgs: String

        // MARK: Boot-args presets
        // The SSH ramdisk read/diagnostic path must NOT include the destructive
        // flags that permit NAND reformatting. Only pass destructiveRestoreBootArgs
        // when an actual restore operation explicitly requires them.

        /// Safe boot-args for SSH ramdisk — read/diagnostics only. No NAND reformat.
        public static let sshRamdiskBootArgs = "rd=md0 debug=0x2014e -v wdt=-1"

        /// Full boot-args including destructive flags. ONLY for actual restore
        /// operations that need NAND reformatting. Never use as a default.
        public static let destructiveRestoreBootArgs =
            sshRamdiskBootArgs + " nand-enable-reformat=1 -restore"

        /// Whether the current bootArgs contain destructive flags.
        public var bootArgsAreDestructive: Bool {
            let tokens = bootArgs.split(separator: " ").map(String.init)
            return tokens.contains("-restore") ||
                   tokens.contains(where: { $0.hasPrefix("nand-enable-reformat=") && $0 != "nand-enable-reformat=0" })
        }
        public var sshUser: String
        public var sshPassword: String
        public var dumpCommand: String
        /// Legacy sink string (superseded by `writeSink`).
        public var sinkCommand: String
        /// The validated write mechanism to hand the transport. nil → read-only /
        /// legacy sink. Thread a validated EffaceableLockerSink here to enable writes.
        public var writeSink: (any WriteSink)?

        public init(gaster: URL, ra1nsn0w: URL? = nil, irecovery: URL? = nil, tsschecker: URL? = nil,
                    forwarder: URL? = nil, sshTool: URL, sshpass: URL? = nil, ramdisk: URL,
                    buildManifest: URL? = nil, firmwareIPSW: URL? = nil, genericTicket: URL? = nil,
                    deviceIdentifier: String = "AudioAccessory1,1",
                    localPort: Int = 2222, gasterTargetsECID: Bool = false,
                    ra1nsn0wFlags: [String] = ["--ipatch-no-force-dfu",
                                               "--kpatch-always-get-task-allow",
                                               "--kpatch-codesignature"],
                    // BUGFIX: was "rd=md0 debug=0x2014e -v wdt=-1 nand-enable-reformat=1 -restore".
                    // Safe by default; opt in to Config.destructiveRestoreBootArgs explicitly.
                    bootArgs: String = Config.sshRamdiskBootArgs,
                    sshUser: String = "root", sshPassword: String = "alpine",
                    dumpCommand: String = SSHRamdiskTransport.Config.defaultDumpCommand,
                    sinkCommand: String = "syscfg_write",
                    writeSink: (any WriteSink)? = nil) {
            self.gaster = gaster; self.ra1nsn0w = ra1nsn0w; self.irecovery = irecovery
            self.tsschecker = tsschecker; self.forwarder = forwarder; self.sshTool = sshTool
            self.sshpass = sshpass; self.ramdisk = ramdisk; self.buildManifest = buildManifest
            self.firmwareIPSW = firmwareIPSW; self.genericTicket = genericTicket; self.deviceIdentifier = deviceIdentifier
            self.localPort = localPort; self.gasterTargetsECID = gasterTargetsECID
            self.ra1nsn0wFlags = ra1nsn0wFlags; self.bootArgs = bootArgs
            self.sshUser = sshUser; self.sshPassword = sshPassword
            self.dumpCommand = dumpCommand; self.sinkCommand = sinkCommand
            self.writeSink = writeSink
        }
    }

    public let config: Config
    public init(config: Config) { self.config = config }

    private func env(_ ecidHex: String) -> [String: String] {
        var e = ToolEnvironment.standard
        if config.gasterTargetsECID { e["GASTER_ECID"] = ecidHex }
        return e
    }

    public func boot(ecid: UInt64, onLog: @escaping @Sendable (String) -> Void) async throws -> BootedPod {
        let ecidHex = String(format: "0x%016llX", ecid)
        let environment = env(ecidHex)

        // Safety: log the boot-args and warn if destructive flags are present.
        onLog("boot-args: \(config.bootArgs)")
        if config.bootArgsAreDestructive {
            onLog("⚠️  WARNING: boot-args contain destructive flags (nand-enable-reformat / -restore). " +
                  "These should only be used for actual restore operations, not read/diagnostic boots.")
        }

        // checkm8 + ramdisk boot: serialized, slot released once it is up.
        try await UnlockCoordinator.shared.run {
            onLog("gaster pwn \(ecidHex)…")
            let pwn = ProcessRunner(executable: config.gaster, arguments: ["pwn"], environment: environment)
            let r = try await pwn.run(onLine: { onLog($0) })
            guard r.exitCode == 0, r.output.contains("Now you can boot untrusted images.") else {
                throw SysCfgError.transportUnavailable("gaster pwn failed — couldn't enter checkm8 to boot the ramdisk.")
            }
            let reset = ProcessRunner(executable: config.gaster, arguments: ["reset"], environment: environment)
            _ = try await reset.run(onLine: { _ in })
            try await Task.sleep(nanoseconds: 2_000_000_000)

            guard let ra1n = config.ra1nsn0w else {
                throw SysCfgError.transportUnavailable("ra1nsn0w isn't installed — needed to boot the SSH ramdisk.")
            }

            // APTicket. checkm8 boots unsigned images, so the shipped generic
            // per-chip ticket is enough — no live, currently-signed ticket
            // needed (that is why tsschecker fails on dropped builds). Only fall
            // back to tsschecker if no generic ticket was provided.
            var ticket: URL? = config.genericTicket
            if let t = ticket {
                onLog("using generic A8 APTicket \(t.lastPathComponent) (checkm8 — no live signing)")
            } else if let irec = config.irecovery, let tss = config.tsschecker {
                var manifest = config.buildManifest
                if manifest == nil, let ipsw = config.firmwareIPSW {
                    manifest = try? await self.extractBuildManifest(fromIPSW: ipsw)
                }
                if let manifest {
                    ticket = try await self.makeTicket(irecovery: irec, tsschecker: tss, manifest: manifest,
                                                       ecidHex: ecidHex, env: environment, onLog: onLog)
                }
            }

            onLog("booting ssh-ramdisk via ra1nsn0w…")
            var args: [String] = []
            if let t = ticket { args += ["-t", t.path] }
            args += ["-r", config.ramdisk.path]
            args += config.ra1nsn0wFlags
            args += ["-b", config.bootArgs]
            let boot = ProcessRunner(executable: ra1n, arguments: args, environment: environment)
            let br = try await boot.run(onLine: { onLog($0) })
            guard br.exitCode == 0 else {
                throw SysCfgError.transportUnavailable("ra1nsn0w couldn't boot the SSH ramdisk (exit \(br.exitCode)). If it needs an APTicket, make sure a HomePod BuildManifest (or the selected firmware) is available.")
            }
        }

        // usbmux → localhost SSH forward: iproxy <localPort> 22.
        var forwarderRunner: ProcessRunner?
        if let fwd = config.forwarder {
            onLog("forwarding pod SSH to 127.0.0.1:\(config.localPort)…")
            let runner = ProcessRunner(executable: fwd, arguments: [String(config.localPort), "22"], environment: environment)
            forwarderRunner = runner
            Task.detached { _ = try? await runner.run(onLine: { _ in }) }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        let transport = SSHRamdiskTransport(config: .init(
            sshTool: config.sshTool, sshpass: config.sshpass, password: config.sshPassword,
            host: "127.0.0.1", port: config.localPort, user: config.sshUser,
            dumpCommand: config.dumpCommand, sinkCommand: config.sinkCommand,
            writeSink: config.writeSink))

        let captured = forwarderRunner
        return BootedPod(transport: transport, shell: transport, teardown: { captured?.cancel() })
    }

    /// Pull BuildManifest.plist out of an .ipsw so tsschecker can personalize a ticket.
    private func extractBuildManifest(fromIPSW ipsw: URL) async throws -> URL {
        let src = LocalFileSource(url: ipsw)
        let dir = try await ZipDirectory.read(from: src)
        guard let e = dir.entry(named: "BuildManifest.plist") else {
            throw SysCfgError.transportUnavailable("No BuildManifest.plist in the selected firmware — can't build an APTicket.")
        }
        let data = try await ZipDirectory.contents(of: e, in: src)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hpr-BuildManifest-\(UUID().uuidString.prefix(8)).plist")
        try data.write(to: out)
        return out
    }

    /// irecovery -q → NONC/SNON, then tsschecker fetches the APTicket (confirmed flags).
    private func makeTicket(irecovery: URL, tsschecker: URL, manifest: URL, ecidHex: String,
                            env: [String: String], onLog: @escaping @Sendable (String) -> Void) async throws -> URL {
        onLog("reading nonce (irecovery -q)…")
        let q = ProcessRunner(executable: irecovery, arguments: ["-q"], environment: env)
        let qr = try await q.run(onLine: { _ in })
        func field(_ key: String) -> String? {
            for raw in qr.output.split(whereSeparator: { $0 == "\n" || $0 == " " }) {
                let t = String(raw)
                if t.hasPrefix(key + ":") {
                    let v = String(t.dropFirst(key.count + 1))
                    if !v.isEmpty { return v }
                }
            }
            for line in qr.output.split(separator: "\n") {
                if let r = line.range(of: key + ":") {
                    let v = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                        .split(separator: " ").first.map(String.init) ?? ""
                    if !v.isEmpty { return v }
                }
            }
            return nil
        }
        guard let nonc = field("NONC"), let snon = field("SNON") else {
            throw SysCfgError.transportUnavailable("Couldn't read NONC/SNON from irecovery -q to build the APTicket.")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hpr-\(nonc.prefix(8)).shsh2")
        onLog("fetching APTicket (tsschecker)…")
        let tss = ProcessRunner(executable: tsschecker,
            arguments: ["-o", "-m", manifest.path, "-d", config.deviceIdentifier, "-e", ecidHex,
                        "-N", nonc, "-S", snon, "-s", out.path],
            environment: env)
        let tr = try await tss.run(onLine: { onLog($0) })
        guard tr.exitCode == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw SysCfgError.transportUnavailable("tsschecker couldn't fetch an APTicket (exit \(tr.exitCode)).")
        }
        return out
    }
}

// MARK: - Controller

/// Orchestrates a SysCfg read or restore end to end: boot → operate → teardown.
public final class SysCfgController: @unchecked Sendable {
    let booter: RamdiskBooter
    public init(booter: RamdiskBooter) { self.booter = booter }

    public func read(ecid: UInt64,
                     onPhase: @escaping @Sendable (SysCfgPhase) -> Void = { _ in },
                     onLog: @escaping @Sendable (String) -> Void = { _ in }) async -> SysCfgJob.Outcome {
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
        let job = SysCfgJob(ecid: ecid, mode: .read, transport: pod.transport, onUpdate: onLog)
        let outcome = await job.run()
        onPhase(.done)
        return outcome
    }

    public func restore(ecid: UInt64, blob: Data,
                        onPhase: @escaping @Sendable (SysCfgPhase) -> Void = { _ in },
                        onLog: @escaping @Sendable (String) -> Void = { _ in }) async -> SysCfgJob.Outcome {
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
        let job = SysCfgJob(ecid: ecid, mode: .restore(blob: blob, confirmed: true), transport: pod.transport, onUpdate: onLog)
        onPhase(.verifying)
        let outcome = await job.run()
        onPhase(.done)
        return outcome
    }
}
