import Foundation

// MARK: - Ramdisk shell
//
// A booted pod exposes a tiny shell so features beyond SysCfg (panic-log pull,
// ioreg diagnostics) can run their own pod-side commands over the same SSH
// endpoint without each one re-implementing the transport.

public protocol RamdiskShell: Sendable {
    /// Run a pod-side command and return its combined text output.
    func run(_ command: String) async throws -> String
    /// Run a pod-side command whose stdout is binary; returns exact bytes.
    /// (Wrapped in markers + base64 so it survives SSH banners / stderr noise.)
    func dumpBinary(_ command: String) async throws -> Data
}

// MARK: - Pre-booted booter (fast path)
//
// The pragmatic path that works TODAY: the tech booted the pod into the SSH
// ramdisk out-of-band (the proven d235j SSHRD flow) and iproxy is already
// forwarding its SSH to a local port. This booter does no unlocking — it just
// hands back a transport pointed at that endpoint. It is also the building
// block the in-app SSHRD booter reuses once it has brought the pod up.
public struct PreBootedBooter: RamdiskBooter {
    public struct Config: Sendable {
        public var sshTool: URL
        public var sshpass: URL?
        public var password: String
        public var host: String
        public var port: Int
        public var user: String
        public var dumpCommand: String
        /// Legacy sink string (superseded by `writeSink`).
        public var sinkCommand: String
        /// The validated write mechanism to hand the transport. nil → read-only /
        /// legacy sink. This is the live path for SysCfg restore from a booted pod,
        /// so a validated EffaceableLockerSink threaded here enables writes.
        public var writeSink: (any WriteSink)?
        public init(sshTool: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                    sshpass: URL? = nil,
                    password: String = "alpine",
                    host: String = "127.0.0.1",
                    port: Int = 2222,
                    user: String = "root",
                    dumpCommand: String = SSHRamdiskTransport.Config.defaultDumpCommand,
                    sinkCommand: String = "syscfg_write",
                    writeSink: (any WriteSink)? = nil) {
            self.sshTool = sshTool; self.sshpass = sshpass; self.password = password
            self.host = host; self.port = port; self.user = user
            self.dumpCommand = dumpCommand; self.sinkCommand = sinkCommand
            self.writeSink = writeSink
        }
    }

    public let config: Config
    /// When set, start an iproxy forward (localPort → 22) before connecting, so
    /// the tech doesn't have to run `iproxy` by hand. When nil, assume a forward
    /// is already up on `config.port`.
    public let forwarder: URL?

    public init(config: Config, forwarder: URL? = nil) {
        self.config = config
        self.forwarder = forwarder
    }

    public func boot(ecid: UInt64, onLog: @escaping @Sendable (String) -> Void) async throws -> BootedPod {
        var forwarderRunner: ProcessRunner?
        if let fwd = forwarder {
            await SSHRDBooter.killStaleForwarders()
            onLog("forwarding pod SSH to 127.0.0.1:\(config.port) (iproxy)…")
            let runner = ProcessRunner(executable: fwd, arguments: [String(config.port), "22"],
                                       environment: ToolEnvironment.standard)
            forwarderRunner = runner
            Task.detached { _ = try? await runner.run(onLine: { _ in }) }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let transport = SSHRamdiskTransport(config: .init(
            sshTool: config.sshTool, sshpass: config.sshpass, password: config.password,
            host: config.host, port: config.port, user: config.user,
            dumpCommand: config.dumpCommand, sinkCommand: config.sinkCommand,
            writeSink: config.writeSink))

        // Prove the endpoint answers before claiming success — a clearer error
        // than a later SysCfg read failing.
        onLog("checking the pod is reachable on \(config.host):\(config.port)…")
        do { _ = try await transport.run("echo hpr-ready") }
        catch {
            forwarderRunner?.cancel()
            throw SysCfgError.transportUnavailable("Couldn't reach a booted pod on \(config.host):\(config.port). Boot the SSH ramdisk first (or let the app boot it), and make sure iproxy is forwarding port \(config.port).")
        }
        onLog("pod is up — ssh ramdisk reachable.")

        let captured = forwarderRunner
        return BootedPod(transport: transport, shell: transport, teardown: { captured?.cancel() })
    }
}

// MARK: - SSHRD layout
//
// Locates a d235j SSHRD_Script working directory and the pieces the proven boot
// needs: the Darwin tools and a built `sshramdisk/` (iBSS/iBEC/ramdisk/…img4).
// The app drives this layout rather than re-implementing SSHRD's create step.
public struct SSHRDLayout: Sendable {
    public let root: URL
    /// Folder under `root` holding the built image set (iBSS/iBEC/ramdisk/…img4).
    public let ramdiskDirName: String

    /// The ordinary SSH ramdisk set built by `sshrd.sh`.
    public static let standardRamdiskDirName = "sshramdisk"
    /// The DIAGS set built by `diags_boot.sh images`: same file names, but the
    /// kernelcache is the patched 11.2 DIAGS one (writable
    /// AppleDiagnosticDataAccess) and the ramdisk carries /diags/syscfg_write.
    public static let diagsRamdiskDirName = "diagsramdisk"

    public init(root: URL, ramdiskDirName: String = SSHRDLayout.standardRamdiskDirName) {
        self.root = root
        self.ramdiskDirName = ramdiskDirName
    }

    public var darwin: URL { root.appendingPathComponent("Darwin", isDirectory: true) }
    public var ramdiskDir: URL { root.appendingPathComponent(ramdiskDirName, isDirectory: true) }
    public var script: URL { root.appendingPathComponent("sshrd.sh") }
    /// The script that builds (and can boot) the DIAGS image set.
    public var diagsScript: URL { root.appendingPathComponent("diags_boot.sh") }

    /// The same checkout, pointed at the DIAGS image set.
    public var diags: SSHRDLayout { SSHRDLayout(root: root, ramdiskDirName: Self.diagsRamdiskDirName) }
    /// Whether this layout boots the DIAGS kernelcache.
    public var isDiags: Bool { ramdiskDirName == Self.diagsRamdiskDirName }

    /// A built ramdisk is present (the 4 boot files that are always required).
    public var hasBuiltRamdisk: Bool {
        let fm = FileManager.default
        return ["iBSS.img4", "iBEC.img4", "ramdisk.img4", "kernelcache.img4"].allSatisfy {
            fm.fileExists(atPath: ramdiskDir.appendingPathComponent($0).path)
        }
    }

    public func img4(_ name: String) -> URL { ramdiskDir.appendingPathComponent(name) }

    /// Prefer the SSHRD copy of a tool (the exact versions proven on-device),
    /// fall back to a provided URL (app-located / PATH).
    public func tool(_ name: String, fallback: URL?) -> URL? {
        let u = darwin.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        return fallback
    }

    /// Standard search locations for a user's SSHRD_Script checkout.
    public static func discover(extraRoots: [URL] = []) -> SSHRDLayout? {
        let fm = FileManager.default
        var roots = extraRoots
        let home = fm.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent("SSHRD_Script", isDirectory: true))
        roots.append(home.appendingPathComponent("homepod/SSHRD_Script", isDirectory: true))
        roots.append(AppPaths.support.appendingPathComponent("SSHRD_Script", isDirectory: true))
        for r in roots where fm.fileExists(atPath: r.appendingPathComponent("sshrd.sh").path) {
            return SSHRDLayout(root: r)
        }
        return nil
    }
}

// MARK: - SSHRD booter (the real in-app boot)
//
// Reproduces, step for step, the boot sequence from the d235j homepod-branch
// `sshrd.sh boot` that is proven on AudioAccessory1,1 — but driven natively so
// there is no bash, no `read -p "press any key"`, and progress is logged:
//
//   gaster pwn → gaster reset → irecovery -f iBSS → iBEC →
//   logo (+setpicture) → ramdisk (+ramdisk) → devicetree (+devicetree) →
//   trustcache (+firmware) → kernelcache → bootx
//
// then iproxy-forward SSH and wait for dropbear. The ramdisk .img4 files come
// from a built SSHRD `sshramdisk/` (SSHRDLayout); building that set is still
// SSHRD's create step (heavy pzb/img4 pipeline), left to the script.
public struct SSHRDBooter: RamdiskBooter {
    public struct Config: Sendable {
        public var layout: SSHRDLayout
        public var gaster: URL
        public var irecovery: URL
        public var forwarder: URL?      // iproxy
        public var sshTool: URL
        public var sshpass: URL?
        public var localPort: Int
        public var sshPassword: String
        public var sshUser: String
        public var dumpCommand: String
        /// Legacy sink string (superseded by `writeSink`).
        public var sinkCommand: String
        /// The validated write mechanism to hand the transport. nil → read-only /
        /// legacy sink.
        public var writeSink: (any WriteSink)?
        /// 0x7000/0x7001/0x8960 get these added by SSHRD's iBEC patch; the files
        /// are already patched, so this is informational only here.
        public var sendTrustcache: Bool
        /// Bounded wait for the pod to enter DFU before pwning.
        public var dfuWaitSeconds: Int
        /// Bounded wait for dropbear to answer after bootx.
        public var sshWaitSeconds: Int
        /// Pause before bootx so the tech can flip the pod upright.
        public var flipWindowSeconds: Int

        public init(layout: SSHRDLayout, gaster: URL, irecovery: URL, forwarder: URL? = nil,
                    sshTool: URL = URL(fileURLWithPath: "/usr/bin/ssh"), sshpass: URL? = nil,
                    localPort: Int = 2222, sshPassword: String = "alpine", sshUser: String = "root",
                    dumpCommand: String = SSHRamdiskTransport.Config.defaultDumpCommand,
                    sinkCommand: String = "syscfg_write",
                    writeSink: (any WriteSink)? = nil,
                    sendTrustcache: Bool = true, dfuWaitSeconds: Int = 60, sshWaitSeconds: Int = 90, flipWindowSeconds: Int = 12) {
            self.layout = layout; self.gaster = gaster; self.irecovery = irecovery
            self.forwarder = forwarder; self.sshTool = sshTool; self.sshpass = sshpass
            self.localPort = localPort; self.sshPassword = sshPassword; self.sshUser = sshUser
            self.dumpCommand = dumpCommand; self.sinkCommand = sinkCommand
            self.writeSink = writeSink
            self.sendTrustcache = sendTrustcache
            self.dfuWaitSeconds = dfuWaitSeconds; self.sshWaitSeconds = sshWaitSeconds
            self.flipWindowSeconds = flipWindowSeconds
        }
    }

    public let config: Config
    public init(config: Config) { self.config = config }

    /// Best-effort: clear any stale iproxy forwards (a dead forward on the port
    /// accepts then resets, which looks like "dropbear didn't answer").
    static func killStaleForwarders() async {
        _ = try? await ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/killall"),
                                     arguments: ["iproxy"], environment: ToolEnvironment.standard).run(onLine: { _ in })
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func irec(_ args: [String], onLog: @escaping @Sendable (String) -> Void) async throws {
        let r = try await ProcessRunner(executable: config.irecovery, arguments: args,
                                        environment: ToolEnvironment.standard).run(onLine: { onLog($0) })
        guard r.exitCode == 0 else {
            throw SysCfgError.transportUnavailable("irecovery \(args.joined(separator: " ")) failed (exit \(r.exitCode)).")
        }
    }

    private func sendImg4(_ name: String, onLog: @escaping @Sendable (String) -> Void) async throws {
        let f = config.layout.img4(name)
        guard FileManager.default.fileExists(atPath: f.path) else {
            throw SysCfgError.transportUnavailable("Missing \(name) in the built ramdisk (\(config.layout.ramdiskDir.path)). Rebuild the SSH ramdisk.")
        }
        onLog("sending \(name)…")
        try await irec(["-f", f.path], onLog: { _ in })
    }

    public func boot(ecid: UInt64, onLog: @escaping @Sendable (String) -> Void) async throws -> BootedPod {
        guard config.layout.hasBuiltRamdisk else {
            if config.layout.isDiags {
                throw SysCfgError.transportUnavailable("No DIAGS image set found at \(config.layout.ramdiskDir.path). Build it first: ./diags_boot.sh images (in the SSHRD_Script folder).")
            }
            throw SysCfgError.transportUnavailable("No built SSH ramdisk found at \(config.layout.ramdiskDir.path). Build it first (SSHRD create step).")
        }
        if config.layout.isDiags {
            onLog("DIAGS boot: patched DIAGS kernelcache (writable AppleDiagnosticDataAccess) from \(config.layout.ramdiskDir.lastPathComponent)/ — no trustcache step.")
        }

        try await UnlockCoordinator.shared.run {
            // Wait for DFU (bounded).
            onLog("waiting for the HomePod in DFU…")
            var inDFU = false
            for _ in 0..<max(1, config.dfuWaitSeconds) {
                let q = try? await ProcessRunner(executable: config.irecovery, arguments: ["-q"],
                                                 environment: ToolEnvironment.standard).run(onLine: { _ in })
                if let out = q?.output, out.contains("MODE: DFU") { inDFU = true; break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard inDFU else {
                throw SysCfgError.transportUnavailable("No HomePod in DFU after \(config.dfuWaitSeconds)s. Flip it upside down with the adapter attached, USB connected, then re-plug power.")
            }

            onLog("gaster pwn (checkm8)…")
            let pwn = try await ProcessRunner(executable: config.gaster, arguments: ["pwn"],
                                              environment: ToolEnvironment.standard).run(onLine: { onLog($0) })
            guard pwn.exitCode == 0 else {
                throw SysCfgError.transportUnavailable("gaster pwn failed — couldn't enter checkm8.")
            }
            _ = try? await ProcessRunner(executable: config.gaster, arguments: ["reset"],
                                         environment: ToolEnvironment.standard).run(onLine: { _ in })

            try await sendImg4("iBSS.img4", onLog: onLog)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try await sendImg4("iBEC.img4", onLog: onLog)
            // A8 (0x7000) is not in the 0x801x set, so no `irecovery -c go` here.
            try await Task.sleep(nanoseconds: 2_000_000_000)

            if FileManager.default.fileExists(atPath: config.layout.img4("logo.img4").path) {
                try await sendImg4("logo.img4", onLog: onLog)
                try? await irec(["-c", "setpicture 0x1"], onLog: { _ in })
            }
            try await sendImg4("ramdisk.img4", onLog: onLog)
            try await irec(["-c", "ramdisk"], onLog: onLog)
            try await sendImg4("devicetree.img4", onLog: onLog)
            try await irec(["-c", "devicetree"], onLog: onLog)
            if config.sendTrustcache,
               FileManager.default.fileExists(atPath: config.layout.img4("trustcache.img4").path) {
                try await sendImg4("trustcache.img4", onLog: onLog)
                try await irec(["-c", "firmware"], onLog: onLog)
            }
            try await sendImg4("kernelcache.img4", onLog: onLog)
            // Flip window: mirrors sshrd.sh's keypress pause. Boot files are
            // staged; give the tech a moment to flip the HomePod upright before
            // bootx, or dropbear won't come up.
            let w = max(0, config.flipWindowSeconds)
            if w > 0 {
                onLog(">>> FLIP THE HOMEPOD UPRIGHT NOW — booting in \(w)s <<<")
                for r in stride(from: w, to: 0, by: -1) {
                    onLog("  bootx in \(r)s…")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            onLog("booting (bootx)…")
            try await irec(["-c", "bootx"], onLog: onLog)
        }

        // Forward SSH and wait for dropbear.
        var forwarderRunner: ProcessRunner?
        if let fwd = config.forwarder {
            await Self.killStaleForwarders()
            onLog("forwarding pod SSH to 127.0.0.1:\(config.localPort) (iproxy)…")
            let runner = ProcessRunner(executable: fwd, arguments: [String(config.localPort), "22"],
                                       environment: ToolEnvironment.standard)
            forwarderRunner = runner
            Task.detached { _ = try? await runner.run(onLine: { _ in }) }
        }

        let transport = SSHRamdiskTransport(config: .init(
            sshTool: config.sshTool, sshpass: config.sshpass, password: config.sshPassword,
            host: "127.0.0.1", port: config.localPort, user: config.sshUser,
            dumpCommand: config.dumpCommand, sinkCommand: config.sinkCommand,
            writeSink: config.writeSink))

        onLog("waiting for the ramdisk to come up on SSH…")
        var up = false
        for _ in 0..<max(1, config.sshWaitSeconds) {
            if (try? await transport.run("echo hpr-ready")) != nil { up = true; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard up else {
            forwarderRunner?.cancel()
            throw SysCfgError.transportUnavailable("The pod booted but dropbear didn't answer on \(config.localPort) within \(config.sshWaitSeconds)s. (If the HomePod is still face-down, flip it upright now.)")
        }
        onLog("ramdisk is up — SSH reachable.")

        let captured = forwarderRunner
        return BootedPod(transport: transport, shell: transport, teardown: { captured?.cancel() })
    }
}

// MARK: - DIAGS kernelcache boot
//
// The DIAGS path (SSHRD_Script/diags_boot.sh) boots a patched 11.2 DIAGS
// kernelcache whose writable AppleDiagnosticDataAccess kext is the SysCfg write
// mechanism. Its boot sequence is the SSHRD one minus the trustcache step
// (AMFI is patched in that kernelcache), reading the image set from
// `diagsramdisk/` — so the same SSHRDBooter drives it with this config.
//
// Boot-args are baked into the DIAGS iBEC when diags_boot.sh builds the images
// (`rd=md0 … -restore amfi_get_out_of_my_way=1 cs_enforcement_disable=1`); the
// app passes none. They do NOT include nand-enable-reformat.
//
// The DiagsKextSink handed to the transport starts unvalidated, so booting this
// way enables SysCfg READ and the sink's read-only probe, never a write, until
// a round-trip has been proven.
public extension SSHRDBooter.Config {
    static func diags(layout: SSHRDLayout, gaster: URL, irecovery: URL, forwarder: URL? = nil,
                      sshTool: URL = URL(fileURLWithPath: "/usr/bin/ssh"), sshpass: URL? = nil,
                      writeSink: (any WriteSink)? = DiagsKextSink()) -> SSHRDBooter.Config {
        SSHRDBooter.Config(layout: layout.diags, gaster: gaster, irecovery: irecovery, forwarder: forwarder,
                           sshTool: sshTool, sshpass: sshpass,
                           writeSink: writeSink, sendTrustcache: false)
    }
}

// MARK: - Diagnostics (read-only panic-log + ioreg pull)
//
// Low-risk, ship-early feature: boot the ssh-ramdisk, pull the panic-log device
// and an ioreg snapshot, hand them back. No writes, no brick risk — same
// plumbing as the SysCfg read, just different source devices.
public struct DiagnosticsBundle: Sendable {
    public var panicLog: Data?
    public var ioregText: String?
    /// Output of the read-only SysCfg write-facility probe (helps pin the sink).
    public var writeProbe: String?
    public var notes: [String]
    public init(panicLog: Data? = nil, ioregText: String? = nil, writeProbe: String? = nil, notes: [String] = []) {
        self.panicLog = panicLog; self.ioregText = ioregText
        self.writeProbe = writeProbe; self.notes = notes
    }
    public var isEmpty: Bool {
        (panicLog?.isEmpty ?? true) && (ioregText?.isEmpty ?? true) && (writeProbe?.isEmpty ?? true)
    }
}

public final class DiagnosticsController: @unchecked Sendable {
    let booter: RamdiskBooter
    /// Fallback panic-log device, used only when the IORegistry lookup below
    /// finds nothing. Device numbers are NOT stable: a real ioreg dump from an
    /// A8 HomePod showed disk2 = Firmware, disk3 = LLB and disk4 = PanicLog —
    /// the old hardcoded "/dev/rdisk3" was reading the LLB, not the panic log.
    public var panicDevice: String
    /// Resolve the panic-log device by its IOMedia name ("Apple PanicLog Media")
    /// before reading. Turn off to force `panicDevice`.
    public var autoDetectPanicDevice: Bool
    public init(booter: RamdiskBooter, panicDevice: String = "/dev/rdisk4", autoDetectPanicDevice: Bool = true) {
        self.booter = booter
        self.panicDevice = panicDevice
        self.autoDetectPanicDevice = autoDetectPanicDevice
    }

    /// Pod-side one-liner that prints `HPPANICDEV=diskN` for the whole disk whose
    /// IOMedia node is named "Apple PanicLog Media". Read-only, sed/grep only.
    /// The pod's ioreg emits ANSI colour codes even into a pipe, so they are
    /// stripped first (ESC via printf — the ramdisk's BSD sed has no `\x1b`).
    static let panicDeviceProbeCommand = #"PATH=/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/bin; E=$(printf '\033'); ioreg -w 0 -r -c IOMedia -l 2>/dev/null | sed -e "s/$E\[[0-9;]*m//g" | sed -n -e '/+-o /h' -e '/"BSD Name" = /{H;g;s/\n/ /;p;}' | grep -i 'PanicLog' | sed -n -e 's/.*"BSD Name" = "\(disk[0-9]*\)".*/HPPANICDEV=\1/p' | head -1"#

    /// Classes whose properties the snapshot reads. Each was captured from a
    /// real pod without incident; `AppleDiagnosticDataAccess` is the writable
    /// twin of the read-only node and only exists on a DIAGS kernelcache boot.
    static let snapshotClasses = [
        "AppleDiagnosticDataAccessReadOnly",
        "AppleDiagnosticDataAccess",
        "ASPStorage",
        "ASPDiagnostic",
        "AppleNANDConfigAccess",
        "AppleEffaceableStorage",
        "IOPMrootDomain",
    ]
    /// Root of the names-only structure listing.
    static let snapshotTreeRootClass = "IOPlatformExpertDevice"

    /// Raw device node of the panic-log region as the registry names it, or nil
    /// when it can't be determined (no ioreg, no such media, unexpected output).
    func detectPanicDevice(shell: RamdiskShell) async -> String? {
        guard let out = try? await shell.run(Self.panicDeviceProbeCommand),
              let r = out.range(of: "HPPANICDEV=disk[0-9]+", options: .regularExpression) else { return nil }
        return "/dev/r" + String(out[r].dropFirst("HPPANICDEV=".count))
    }

    public enum Outcome: Sendable {
        case ok(DiagnosticsBundle)
        case failed(String)
    }

    public func pull(ecid: UInt64,
                     onPhase: @escaping @Sendable (SysCfgPhase) -> Void = { _ in },
                     onLog: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        onPhase(.unlocking)
        let pod: BootedPod
        do {
            onPhase(.bootingRamdisk)
            pod = try await booter.boot(ecid: ecid, onLog: onLog)
        } catch {
            return .failed(error.localizedDescription)
        }
        defer { Task { await pod.teardown() } }
        guard let shell = pod.shell else {
            return .failed("This booter doesn't expose a shell to pull diagnostics.")
        }

        onPhase(.working)
        var bundle = DiagnosticsBundle()

        // Panic log (read-only dd of the panic device). Large block size: 512-byte
        // reads return nothing on this NAND — needs big aligned blocks.
        var panicDevice = self.panicDevice
        if autoDetectPanicDevice {
            if let found = await detectPanicDevice(shell: shell) {
                if found != panicDevice { onLog("panic log media is \(found) on this pod (default was \(panicDevice)).") }
                panicDevice = found
            } else {
                bundle.notes.append("Couldn't identify the panic-log device from the IORegistry; fell back to \(panicDevice), which may be a different region on this pod.")
            }
        }
        onLog("reading panic log from \(panicDevice)…")
        do {
            let data = try await shell.dumpBinary("PATH=/usr/bin:/usr/sbin:/bin:/sbin dd if=\(panicDevice) bs=1m 2>/dev/null")
            if data.isEmpty {
                bundle.notes.append("Panic device \(panicDevice) returned no data (may be empty — that's normal on a healthy pod).")
            } else {
                bundle.panicLog = data
                onLog("panic log: \(data.count) bytes.")
            }
        } catch {
            bundle.notes.append("Couldn't read \(panicDevice): \(error.localizedDescription)")
        }

        // ioreg snapshot. NEVER `ioreg -l` (the whole registry with properties):
        // it kernel-panics the pod by serialising unstable driver nodes in the
        // ramdisk. Only targeted `ioreg -r -c <Class> -l` queries on classes
        // known to be safe, built by RamdiskIOReg (PATH + ANSI stripping).
        onLog("capturing ioreg diagnostics snapshot (targeted)…")
        do {
            let safeClasses = Self.snapshotClasses
            var parts: [String] = []
            var seen = Set<String>()
            var captured = 0
            for cls in safeClasses {
                guard let query = RamdiskIOReg.query(forClass: cls) else { continue }
                let result = try await shell.run(RamdiskIOReg.command(query))
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                // A subclass can answer for its parent's query; keep one copy.
                if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                    parts.append("// === \(cls) ===")
                    parts.append(result)
                    captured += 1
                }
            }
            // Registry structure, node NAMES only: no -l, so no property is read.
            if let treeQuery = RamdiskIOReg.query(forClass: Self.snapshotTreeRootClass, properties: false) {
                let tree = try await shell.run(RamdiskIOReg.command(treeQuery))
                if !tree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append("// === node tree (names only, no properties) ===")
                    parts.append(tree)
                }
            }
            let text = parts.joined(separator: "\n")
            if !text.isEmpty { bundle.ioregText = text; onLog("ioreg snapshot: \(text.count) chars (\(captured) of \(safeClasses.count) targeted classes + node names).") }
        } catch {
            bundle.notes.append("Couldn't capture ioreg: \(error.localizedDescription)")
        }

        // SysCfg write-facility probe (read-only) — helps pin the write sink.
        onLog("probing SysCfg write facilities (read-only)…")
        do {
            let text = try await shell.run(SSHRamdiskTransport.writeProbeCommand)
            if !text.isEmpty { bundle.writeProbe = text; onLog("write probe captured (\(text.count) chars).") }
        } catch {
            bundle.notes.append("Write probe failed: \(error.localizedDescription)")
        }

        onPhase(.done)
        if bundle.isEmpty && bundle.notes.isEmpty {
            return .failed("Nothing came back from the pod.")
        }
        return .ok(bundle)
    }
}

// MARK: - SSHRD ramdisk builder (create step)
//
// Drives the d235j SSHRD create step (`sshrd.sh [ota] <version>`) so the app can
// build the `sshramdisk/` set without the tech running a terminal. This is the
// heavy pzb/img4/iBoot64Patcher pipeline — faithfully reused rather than
// re-implemented. NOTE: the create step reads the pod's CPID and runs gaster, so
// the HomePod must be in DFU and connected while it runs.
//
// FIRMWARE PINNING: the version defaults to RamdiskFirmware.pinnedVersion (18.3),
// NOT 17.5. The SysCfg write RE (SYSCFG_WRITE_FINDINGS.md) and the shipping
// restore IPSW are both 18.3/22K557; the booted ramdisk's kernel must match the
// build the write path was validated against, or the AppleEffaceableStorage
// selector indices and gates the RE pinned may not line up. See the rationale
// block on RamdiskFirmware in SysCfgSession.swift.
public struct SSHRDRamdiskBuilder: Sendable {
    public let layout: SSHRDLayout
    public let version: String
    public let ota: Bool
    public init(layout: SSHRDLayout, version: String = RamdiskFirmware.pinnedVersion, ota: Bool = true) {
        self.layout = layout; self.version = version; self.ota = ota
    }

    public func run(onLog: @escaping @Sendable (String) -> Void) async throws -> URL {
        guard FileManager.default.fileExists(atPath: layout.script.path) else {
            throw SysCfgError.transportUnavailable("No sshrd.sh at \(layout.script.path).")
        }
        var args = [layout.script.path]
        if ota { args.append("ota") }
        args.append(version)
        onLog("running SSHRD create step: sshrd.sh \(ota ? "ota " : "")\(version) (HomePod must be in DFU)…")
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"),
                                   arguments: args,
                                   environment: ToolEnvironment.standard,
                                   currentDirectory: layout.root)
        let r = try await runner.run(onLine: { onLog($0) })
        guard r.exitCode == 0 else {
            throw SysCfgError.transportUnavailable("SSHRD create step failed (exit \(r.exitCode)). Make sure the HomePod is in DFU and the SSHRD toolchain is set up.")
        }
        guard layout.hasBuiltRamdisk else {
            throw SysCfgError.transportUnavailable("SSHRD finished but no built ramdisk appeared in \(layout.ramdiskDir.path).")
        }
        onLog("SSH ramdisk built at \(layout.ramdiskDir.path).")
        return layout.ramdiskDir
    }
}
