import Foundation
import HomePodRestoreCore

enum SysCfgKind { case read, restore }

/// How a pod is brought into the SSH ramdisk before a SysCfg / diagnostics op.
enum SysCfgBootMode: String, CaseIterable, Identifiable {
    /// The tech already booted the pod (proven d235j SSHRD flow); the app just
    /// connects (and starts an iproxy forward). Works today.
    case preBooted
    /// The app drives the proven SSHRD boot sequence itself (gaster + irecovery
    /// chain) from a built SSHRD ramdisk. The "no terminal" goal.
    case sshrd
    /// Boot Apple's factory DIAGS environment via development iBoot from the
    /// ProtoPod dump. Gives serial-console access to the `syscfg` command for
    /// full SysCfg read/write — the NAND replacement path. Interaction is over
    /// UART (serial), not SSH.
    case factoryDiags
    /// (Obsolete) The app boots a patched DIAGS kernelcache via SSH ramdisk.
    /// Superseded by factoryDiags — the patched-kernel approach never got past
    /// iBEC validation with RELEASE iBoot. Kept for reference only.
    case diags
    /// Legacy in-app gaster + ra1nsn0w path (kept for reference; unreliable).
    case legacy

    var id: String { rawValue }
    var title: String {
        switch self {
        case .preBooted:    return "Pod already booted (SSHRD)"
        case .sshrd:        return "Boot SSH Ramdisk (diagnostics)"
        case .factoryDiags: return "Boot Factory DIAGS (SysCfg write)"
        case .diags:        return "Boot DIAGS kernel (obsolete)"
        case .legacy:       return "Legacy (ra1nsn0w)"
        }
    }
    var blurb: String {
        switch self {
        case .preBooted:    return "You booted the SSH ramdisk already — the app connects over USB."
        case .sshrd:        return "The app runs the proven SSHRD boot (gaster → irecovery) on your pod."
        case .factoryDiags: return "Boots Apple's factory DIAGS via development iBoot. Gives full SysCfg read/write over serial (UART). Required for NAND replacement provisioning."
        case .diags:        return "Obsolete. The patched DIAGS kernel approach was superseded by Factory DIAGS. Use that instead."
        case .legacy:       return "Old built-in boot path. Known-unreliable; here only as a fallback."
        }
    }

    /// Whether the user should see this mode in the picker. Hide obsolete modes
    /// unless the user has explicitly selected them.
    var isVisible: Bool {
        switch self {
        case .preBooted, .sshrd, .factoryDiags: return true
        case .diags, .legacy: return false
        }
    }

    /// Whether this mode uses SSH (vs serial/UART).
    var usesSSH: Bool {
        switch self {
        case .preBooted, .sshrd, .diags, .legacy: return true
        case .factoryDiags: return false
        }
    }
}

/// UI state for a read-only diagnostics pull (panic log + ioreg).
struct DiagUIState: Identifiable {
    var id: UInt32 { locationID }
    var locationID: UInt32
    var ecid: UInt64
    var phase: SysCfgPhase
    var log: [String]
    var bundle: DiagnosticsBundle?
    var done: Bool
    var error: String?
    var running: Bool
    var ecidShort: String { "…" + String(format: "%016llX", ecid).suffix(6) }
}

/// UI state for an app-driven SSHRD ramdisk build (create step).
struct SSHRDBuildState {
    var version: String
    var log: [String]
    var error: String?
    var finished: URL?
    var running: Bool { error == nil && finished == nil }
}

/// UI state for a SysCfg read/restore shown in the SysCfg sheet.
struct SysCfgUIState: Identifiable {
    var id: UInt32 { locationID }
    var locationID: UInt32
    var ecid: UInt64
    var kind: SysCfgKind
    var phase: SysCfgPhase
    var log: [String]
    /// read: the blob read back. restore: the blob being written (for display).
    var dump: SysCfgData?
    var done: Bool
    var error: String?
    var running: Bool

    var ecidShort: String { "…" + String(format: "%016llX", ecid).suffix(6) }
}

/// UI state for an SSH-ramdisk build.
struct SSHRamdiskBuildState: Identifiable {
    var id: String { release.build }
    var release: BuildableRelease
    var update: SSHRamdiskBuilder.Update
    var error: String?
    var finished: URL?
    var running: Bool { error == nil && finished == nil }
}

@MainActor
extension AppModel {

    // MARK: Boot Factory DIAGS (serial console — SysCfg write path)

    /// The pre-built Factory DIAGS files (iBSS.img4, iBEC.img4, diag.img4).
    /// These are universal — they work on any HomePod 1st gen.
    private static let diagsFileNames = ["iBSS.img4", "iBEC.img4", "diag.img4"]

    /// Search paths for the pre-built Factory DIAGS files.
    private static var diagsSearchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Downloads/diagsstuffnic"),
            home.appendingPathComponent("homepod/SSHRD_Script"),
            home.appendingPathComponent("SSHRD_Script"),
            AppPaths.support.appendingPathComponent("DiagsBoot"),
        ]
    }

    /// Find the directory containing the pre-built DIAGS boot files.
    private func findDiagsFiles() -> (dir: URL, gaster: URL, irecovery: URL)? {
        let fm = FileManager.default
        // Find DIAGS files
        var diagsDir: URL?
        for search in Self.diagsSearchPaths {
            let allPresent = Self.diagsFileNames.allSatisfy {
                fm.fileExists(atPath: search.appendingPathComponent($0).path)
            }
            if allPresent { diagsDir = search; break }
        }
        guard let dir = diagsDir else { return nil }

        // Find gaster
        let gaster: URL? = ToolLocator.locate(.gaster)?.url
            ?? SSHRDLayout.discover()?.tool("gaster", fallback: nil)
        // Find irecovery
        let irecovery: URL? = ToolLocator.locate(.irecovery)?.url
            ?? SSHRDLayout.discover()?.tool("irecovery", fallback: nil)

        guard let g = gaster, let ir = irecovery else { return nil }
        return (dir, g, ir)
    }

    /// Boot Apple's factory DIAGS environment directly from the app.
    /// Runs: gaster pwn/reset, then sends dev iBSS, iBEC, diag.img4 via
    /// irecovery, then issues the `go` command. After boot the user
    /// interacts via serial (UART) — open DIAGS Shell in the sidebar.
    func bootFactoryDiags(on device: ConnectedDevice) {
        guard let ecid = device.iboot?.ecid else { return }
        let loc = device.locationID

        guard let found = findDiagsFiles() else {
            let searched = Self.diagsSearchPaths.map(\.path).joined(separator: "\n  ")
            syscfg = SysCfgUIState(locationID: loc, ecid: ecid, kind: .read, phase: .bootingRamdisk,
                                   log: ["Looked for iBSS.img4 + iBEC.img4 + diag.img4 in:", "  \(searched)"],
                                   dump: nil, done: false,
                                   error: "DIAGS boot files not found. Place iBSS.img4, iBEC.img4, and diag.img4 in ~/Downloads/diagsstuffnic/ — see docs/diags-boot.md.",
                                   running: false)
            return
        }

        let dir = found.dir
        let gaster = found.gaster
        let irecovery = found.irecovery

        syscfg = SysCfgUIState(locationID: loc, ecid: ecid, kind: .read, phase: .bootingRamdisk,
                               log: ["Booting Factory DIAGS from \(dir.path)..."],
                               dump: nil, done: false, error: nil, running: true)
        syscfgTask?.cancel()
        syscfgTask = Task { [weak self] in
            // Build the sequence of commands
            let steps: [(label: String, args: [String])] = [
                ("Exploiting (gaster pwn)...", [gaster.path, "pwn"]),
                ("Resetting USB...", [gaster.path, "reset"]),
                ("Sending dev iBSS...", [irecovery.path, "-f", dir.appendingPathComponent("iBSS.img4").path]),
                ("Sending dev iBEC...", [irecovery.path, "-f", dir.appendingPathComponent("iBEC.img4").path]),
                ("Sending diag.img4...", [irecovery.path, "-f", dir.appendingPathComponent("diag.img4").path]),
                ("Booting (go)...", [irecovery.path, "-c", "go"]),
            ]

            // Delays after specific steps (seconds)
            let delaysAfter: [Int: UInt64] = [1: 2, 2: 3, 3: 3]

            for (i, step) in steps.enumerated() {
                await MainActor.run { self?.appendSysCfgLog(step.label) }

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: step.args[0])
                proc.arguments = Array(step.args.dropFirst())
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run { self?.appendSysCfgLog("  " + output.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    }
                    if proc.terminationStatus != 0 && i < 4 {
                        // gaster and early irecovery steps: non-zero is a real error
                        await MainActor.run {
                            self?.syscfg?.error = "\(step.label) failed (exit \(proc.terminationStatus)). Is the pod in DFU?"
                            self?.syscfg?.running = false
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        self?.syscfg?.error = "Failed: \(error.localizedDescription)"
                        self?.syscfg?.running = false
                    }
                    return
                }

                if let delay = delaysAfter[i] {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                }
            }

            await MainActor.run {
                guard var st = self?.syscfg else { return }
                st.done = true
                st.phase = .done
                st.running = false
                st.log.append("")
                st.log.append("✅ Factory DIAGS booted!")
                st.log.append("")
                st.log.append("Open DIAGS Shell in the sidebar, select your")
                st.log.append("USB-to-serial adapter, and click Connect.")
                self?.syscfg = st
            }
        }
    }

        // MARK: Read SysCfg (de-risk: prove the path on a known-good pod)

    func readSysCfg(on device: ConnectedDevice) {
        guard let ecid = device.iboot?.ecid else { return }
        let loc = device.locationID

        let (maybeController, setupError) = makeSysCfgController(ecid: ecid)
        guard let controller = maybeController else {
            syscfg = SysCfgUIState(locationID: loc, ecid: ecid, kind: .read, phase: .bootingRamdisk,
                                   log: [], dump: nil, done: false, error: setupError, running: false)
            return
        }

        syscfg = SysCfgUIState(locationID: loc, ecid: ecid, kind: .read, phase: .unlocking,
                               log: [], dump: nil, done: false, error: nil, running: true)
        syscfgTask?.cancel()
        syscfgTask = Task { [weak self] in
            let outcome = await controller.read(
                ecid: ecid,
                onPhase: { p in Task { @MainActor in self?.syscfg?.phase = p } },
                onLog: { line in Task { @MainActor in self?.appendSysCfgLog(line) } })
            await MainActor.run {
                guard var st = self?.syscfg else { return }
                st.running = false
                switch outcome {
                case .read(let data): st.dump = data; st.done = true; st.phase = .done
                case .failed(let msg): st.error = msg
                default: break
                }
                self?.syscfg = st
            }
        }
    }

    // MARK: Booted-pod entry points (no DFU device needed)
    //
    // A pod already booted into the SSH ramdisk is NOT a DFU/recovery device, so
    // the USB scanner won't list it. These run against it directly over SSH
    // (always the pre-booted booter — the pod is already up), using a sentinel
    // location/ecid since there's no iBoot device to read them from.

    /// sshpass/iproxy, preferring app-located copies, then the SSHRD Darwin/ dir
    /// (so a tech with only an SSHRD checkout still authenticates to dropbear).
    func bestSSHpass() -> URL? {
        locateOnPath("sshpass") ?? SSHRDLayout.discover()?.tool("sshpass", fallback: nil)
    }
    func bestIproxy() -> URL? {
        locateOnPath("iproxy") ?? SSHRDLayout.discover()?.tool("iproxy", fallback: nil)
    }

    private func preBootedController() -> SysCfgController {
        let cfg = PreBootedBooter.Config(sshTool: URL(fileURLWithPath: "/usr/bin/ssh"),
                                         sshpass: bestSSHpass())
        return SysCfgController(booter: PreBootedBooter(config: cfg, forwarder: bestIproxy()))
    }

    /// Read SysCfg from a pod that's already booted into the ramdisk.
    func readSysCfgBooted() {
        syscfg = SysCfgUIState(locationID: 0, ecid: 0, kind: .read, phase: .connecting,
                               log: [], dump: nil, done: false, error: nil, running: true)
        let controller = preBootedController()
        syscfgTask?.cancel()
        syscfgTask = Task { [weak self] in
            let outcome = await controller.read(
                ecid: 0,
                onPhase: { p in Task { @MainActor in self?.syscfg?.phase = p } },
                onLog: { line in Task { @MainActor in self?.appendSysCfgLog(line) } })
            await MainActor.run {
                guard var st = self?.syscfg else { return }
                st.running = false
                switch outcome {
                case .read(let data): st.dump = data; st.done = true; st.phase = .done
                case .failed(let msg): st.error = msg
                default: break
                }
                self?.syscfg = st
            }
        }
    }

    /// Pull diagnostics from a pod that's already booted into the ramdisk.
    func pullDiagnosticsBooted() {
        diag = DiagUIState(locationID: 0, ecid: 0, phase: .connecting,
                           log: [], bundle: nil, done: false, error: nil, running: true)
        let cfg = PreBootedBooter.Config(sshTool: URL(fileURLWithPath: "/usr/bin/ssh"),
                                         sshpass: bestSSHpass())
        let controller = DiagnosticsController(booter: PreBootedBooter(config: cfg, forwarder: bestIproxy()))
        diagTask?.cancel()
        diagTask = Task { [weak self] in
            let outcome = await controller.pull(
                ecid: 0,
                onPhase: { p in Task { @MainActor in self?.diag?.phase = p } },
                onLog: { line in Task { @MainActor in self?.appendDiagLog(line) } })
            await MainActor.run {
                guard var st = self?.diag else { return }
                st.running = false
                switch outcome {
                case .ok(let b): st.bundle = b; st.done = true; st.phase = .done
                case .failed(let msg): st.error = msg
                }
                self?.diag = st
            }
        }
    }

    // MARK: Restore SysCfg (write a saved dump back to a replacement chip)

    func restoreSysCfg(on device: ConnectedDevice, from url: URL) {
        guard let ecid = device.iboot?.ecid else { return }
        let loc = device.locationID

        guard let data = try? Data(contentsOf: url) else {
            syscfg = SysCfgUIState(locationID: loc, ecid: ecid, kind: .restore, phase: .working,
                                   log: [], dump: nil, done: false, error: "Couldn't read that dump file.", running: false)
            return
        }
        // Validate before touching hardware — the write is verbatim, so a bad
        // dump must never reach the chip.
        let parsed = SysCfgParser.parse(data)
        guard parsed.looksValid, parsed.hasEssentials else {
            let why = parsed.looksValid
                ? "This dump is missing required identity fields (serial / Wi-Fi / Bluetooth) — not safe to write."
                : "This file doesn't look like a SysCfg dump — not writing it."
            syscfg = SysCfgUIState(locationID: loc, ecid: ecid, kind: .restore, phase: .working,
                                   log: [], dump: parsed, done: false, error: why, running: false)
            return
        }

        let (maybeController, setupError) = makeSysCfgController(ecid: ecid)
        guard let controller = maybeController else {
            syscfg = SysCfgUIState(locationID: loc, ecid: ecid, kind: .restore, phase: .bootingRamdisk,
                                   log: [], dump: parsed, done: false, error: setupError, running: false)
            return
        }

        syscfg = SysCfgUIState(locationID: loc, ecid: ecid, kind: .restore, phase: .unlocking,
                               log: [], dump: parsed, done: false, error: nil, running: true)
        syscfgTask?.cancel()
        syscfgTask = Task { [weak self] in
            let outcome = await controller.restore(
                ecid: ecid, blob: parsed.rawBytes,
                onPhase: { p in Task { @MainActor in self?.syscfg?.phase = p } },
                onLog: { line in Task { @MainActor in self?.appendSysCfgLog(line) } })
            await MainActor.run {
                guard var st = self?.syscfg else { return }
                st.running = false
                switch outcome {
                case .restored: st.done = true; st.phase = .done
                case .failed(let msg): st.error = msg
                default: break
                }
                self?.syscfg = st
            }
        }
    }

    /// Restore a saved SysCfg dump to a pod already booted into the ramdisk.
    func restoreSysCfgBooted(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            syscfg = SysCfgUIState(locationID: 0, ecid: 0, kind: .restore, phase: .working,
                                   log: [], dump: nil, done: false, error: "Couldn't read that dump file.", running: false)
            return
        }
        let parsed = SysCfgParser.parse(data)
        guard parsed.looksValid, parsed.hasEssentials else {
            let why = parsed.looksValid
                ? "This dump is missing required identity fields (serial / Wi-Fi / Bluetooth) — not safe to write."
                : "This file doesn't look like a SysCfg dump — not writing it."
            syscfg = SysCfgUIState(locationID: 0, ecid: 0, kind: .restore, phase: .working,
                                   log: [], dump: parsed, done: false, error: why, running: false)
            return
        }
        syscfg = SysCfgUIState(locationID: 0, ecid: 0, kind: .restore, phase: .connecting,
                               log: [], dump: parsed, done: false, error: nil, running: true)
        let controller = preBootedController()
        syscfgTask?.cancel()
        syscfgTask = Task { [weak self] in
            let outcome = await controller.restore(
                ecid: 0, blob: parsed.rawBytes,
                onPhase: { p in Task { @MainActor in self?.syscfg?.phase = p } },
                onLog: { line in Task { @MainActor in self?.appendSysCfgLog(line) } })
            await MainActor.run {
                guard var st = self?.syscfg else { return }
                st.running = false
                switch outcome {
                case .restored: st.done = true; st.phase = .done
                case .failed(let msg): st.error = msg
                default: break
                }
                self?.syscfg = st
            }
        }
    }

    // MARK: Build the SSHRD ramdisk (app-driven create step)

    func buildSSHRDRamdisk(version: String = RamdiskFirmware.pinnedVersion) {
        guard sshrdBuild?.running != true else { return }
        guard let layout = SSHRDLayout.discover() else {
            sshrdBuild = SSHRDBuildState(version: version, log: [], error: "No SSHRD_Script checkout found (looked in ~/SSHRD_Script).", finished: nil)
            return
        }
        sshrdBuild = SSHRDBuildState(version: version, log: [], error: nil, finished: nil)
        let builder = SSHRDRamdiskBuilder(layout: layout, version: version, ota: true)
        sshrdBuildTask?.cancel()
        sshrdBuildTask = Task { [weak self] in
            do {
                let url = try await builder.run(onLog: { line in Task { @MainActor in self?.appendSSHRDLog(line) } })
                await MainActor.run { self?.sshrdBuild?.finished = url }
            } catch {
                await MainActor.run { self?.sshrdBuild?.error = error.localizedDescription }
            }
        }
    }

    func clearSSHRDBuild() { if sshrdBuild?.running != true { sshrdBuild = nil } }

    private func appendSSHRDLog(_ line: String) {
        guard var st = sshrdBuild else { return }
        st.log.append(line)
        if st.log.count > 400 { st.log.removeFirst(st.log.count - 400) }
        sshrdBuild = st
    }

    func dismissSysCfg() {
        syscfgTask?.cancel()
        syscfgTask = nil
        syscfg = nil
    }

    /// Write a read/recovered SysCfg blob to a file the tech chooses.
    func writeDump(_ data: Data, to url: URL) -> String? {
        do { try data.write(to: url, options: .atomic); return nil }
        catch { return error.localizedDescription }
    }

    // MARK: Build the SSH ramdisk

    func buildSSHRamdisk(_ release: BuildableRelease) {
        guard sshRamdiskBuild?.running != true else { return }
        let b = SSHRamdiskBuilder(release: release)
        sshRamdiskBuilder = b
        sshRamdiskBuild = SSHRamdiskBuildState(release: release,
                                               update: .init(stage: .checking, detail: ""),
                                               error: nil, finished: nil)
        Task { [weak self] in
            do {
                let url = try await b.run { u in Task { @MainActor in self?.sshRamdiskBuild?.update = u } }
                await MainActor.run { self?.sshRamdiskBuild?.finished = url }
            } catch {
                await MainActor.run { self?.sshRamdiskBuild?.error = error.localizedDescription }
            }
            await MainActor.run { self?.sshRamdiskBuilder = nil }
        }
    }

    /// Loads releases if needed, picks one with an Apple TV donor, and builds.
    func buildDefaultSSHRamdisk(forPod device: ConnectedDevice?) {
        Task { [weak self] in
            guard let self else { return }
            if self.releases.isEmpty { await self.loadReleases() }
            guard let release = self.releases.first(where: { $0.donor != nil }) else {
                if var st = self.syscfg {
                    st.error = "Couldn't find an Apple TV HD donor on ipsw.me to build the SSH ramdisk from."
                    st.running = false
                    self.syscfg = st
                }
                return
            }
            self.buildSSHRamdisk(release)
        }
    }

    func cancelSSHRamdiskBuild() { sshRamdiskBuilder?.cancel() }
    func clearSSHRamdiskBuild() { if sshRamdiskBuild?.running != true { sshRamdiskBuild = nil } }

    // MARK: Helpers

    private func appendSysCfgLog(_ line: String) {
        guard var st = syscfg else { return }
        st.log.append(line)
        if st.log.count > 400 { st.log.removeFirst(st.log.count - 400) }
        syscfg = st
    }

    private func makeSysCfgController(ecid: UInt64) -> (SysCfgController?, String?) {
        let (booter, err) = makeBooter(ecid: ecid)
        guard let booter else { return (nil, err) }
        return (SysCfgController(booter: booter), nil)
    }

    /// Build the right RamdiskBooter for the current boot mode. Shared by
    /// SysCfg read/restore and the diagnostics pull.
    ///
    /// FIX (diag-boot): takes an optional explicit `mode` so a caller that KNOWS
    /// the pod is in DFU (see `makeDFUBooter`) can force a real boot path
    /// instead of inheriting `.preBooted` from the setting. Default (nil) keeps
    /// the old behaviour — the current `syscfgBootMode` — for existing callers.
    func makeBooter(ecid: UInt64, mode: SysCfgBootMode? = nil) -> (RamdiskBooter?, String?) {
        let ssh = URL(fileURLWithPath: "/usr/bin/ssh")
        switch mode ?? syscfgBootMode {
        case .preBooted:
            let cfg = PreBootedBooter.Config(sshTool: ssh, sshpass: locateOnPath("sshpass"))
            return (PreBootedBooter(config: cfg, forwarder: locateOnPath("iproxy")), nil)

        case .sshrd:
            guard let layout = SSHRDLayout.discover() else {
                return (nil, "No SSHRD_Script checkout found (looked in ~/SSHRD_Script). Clone the d235j homepod branch there, or switch to \"Pod already booted\".")
            }
            guard layout.hasBuiltRamdisk else {
                return (nil, "Found SSHRD at \(layout.root.path) but no built ramdisk yet. Run its create step once (e.g. ./sshrd.sh ota \(RamdiskFirmware.pinnedVersion)), then try again.")
            }
            guard let gaster = layout.tool("gaster", fallback: ToolLocator.locate(.gaster)?.url) else {
                return (nil, "gaster isn't available (not in the SSHRD Darwin/ folder or installed). Open Setup to install the tools.")
            }
            guard let irecovery = layout.tool("irecovery", fallback: ToolLocator.locate(.irecovery)?.url) else {
                return (nil, "irecovery isn't available (not in the SSHRD Darwin/ folder or installed).")
            }
            let cfg = SSHRDBooter.Config(
                layout: layout,
                gaster: gaster,
                irecovery: irecovery,
                forwarder: layout.tool("iproxy", fallback: locateOnPath("iproxy")),
                sshTool: ssh,
                sshpass: layout.tool("sshpass", fallback: locateOnPath("sshpass")))
            return (SSHRDBooter(config: cfg), nil)

        case .factoryDiags:
            // Factory DIAGS: boots Apple's diag.img4 via development iBoot from
            // the ProtoPod dump. This gives a serial console with the `syscfg`
            // command for full SysCfg read/write. NO SSH — interaction is UART.
            // The app handles the boot sequence; the user uses their serial
            // terminal for commands.
            return (nil, "Factory DIAGS boots via serial console — use dev_boot.sh from Terminal, then interact over UART. Or use \"Boot Factory DIAGS\" on the device card. Then open DIAGS Shell in the sidebar to run commands. See docs/diags-boot.md for the full workflow.")

        case .diags:
            // OBSOLETE: patched DIAGS kernelcache approach. Never got past iBEC
            // validation with RELEASE iBoot. Superseded by .factoryDiags.
            // Kept for code reference only.
            guard let layout = SSHRDLayout.discover() else {
                return (nil, "No SSHRD_Script checkout found. This mode is obsolete — use \"Factory DIAGS\" instead.")
            }
            let diags = layout.diags
            guard diags.hasBuiltRamdisk else {
                return (nil, "No DIAGS image set found. This mode is obsolete — use \"Factory DIAGS\" instead.")
            }
            guard let gaster = layout.tool("gaster", fallback: ToolLocator.locate(.gaster)?.url) else {
                return (nil, "gaster isn't available.")
            }
            guard let irecovery = layout.tool("irecovery", fallback: ToolLocator.locate(.irecovery)?.url) else {
                return (nil, "irecovery isn't available.")
            }
            let cfg = SSHRDBooter.Config.diags(
                layout: layout,
                gaster: gaster,
                irecovery: irecovery,
                forwarder: layout.tool("iproxy", fallback: locateOnPath("iproxy")),
                sshTool: ssh,
                sshpass: layout.tool("sshpass", fallback: locateOnPath("sshpass")))
            return (SSHRDBooter(config: cfg), nil)

        case .legacy:
            guard let gaster = ToolLocator.locate(.gaster)?.url else {
                return (nil, "gaster isn't installed. Open Setup to install the tools.")
            }
            guard let ramdisk = cachedSSHRamdisk() else {
                return (nil, "No SSH ramdisk has been built yet. Build one first (the button below), then try again.")
            }
            let cfg = GasterRamdiskBooter.Config(
                gaster: gaster,
                ra1nsn0w: ToolLocator.locate(.ra1nsn0w)?.url,
                irecovery: ToolLocator.locate(.irecovery)?.url,
                tsschecker: ToolLocator.locate(.tsschecker)?.url,
                forwarder: locateOnPath("iproxy"),
                sshTool: ssh,
                sshpass: locateOnPath("sshpass"),
                ramdisk: ramdisk,
                firmwareIPSW: selectedFirmware.map { URL(fileURLWithPath: $0.path) },
                genericTicket: bundledApticket(),
                gasterTargetsECID: gasterSupportsECID)
            return (GasterRamdiskBooter(config: cfg), nil)
        }
    }

    /// FIX (diag-boot): booter for a pod that is known to be sitting in DFU.
    ///
    /// A DFU pod is by definition NOT booted into the ramdisk, so `.preBooted`
    /// (PreBootedBooter: iproxy + ssh only, no checkm8 / no ramdisk boot) can
    /// never be right here. `.preBooted` is also what `syscfgBootMode` defaults
    /// to on every launch where no SSHRD checkout was found and the tech never
    /// touched the picker — which made the DFU path skip the boot entirely.
    ///
    /// - `.sshrd` / `.diags` / `.legacy` selected: honoured as-is (including their setup
    ///   errors, so the tech sees why the mode they picked can't run).
    /// - `.preBooted` selected: ignored for DFU. Prefer SSHRD when it can boot
    ///   right now, otherwise fall back to the legacy ra1nsn0w path.
    func makeDFUBooter(ecid: UInt64) -> (RamdiskBooter?, String?) {
        if syscfgBootMode != .preBooted {
            return makeBooter(ecid: ecid, mode: syscfgBootMode)
        }
        let (sshrd, sshrdError) = makeBooter(ecid: ecid, mode: .sshrd)
        if let sshrd { return (sshrd, nil) }
        let (legacy, legacyError) = makeBooter(ecid: ecid, mode: .legacy)
        if let legacy { return (legacy, nil) }
        // Neither path is ready. If an SSHRD checkout exists its error is the
        // most actionable one (e.g. "no built ramdisk yet"); otherwise explain
        // that the pod has to be booted and what's missing for the fallback.
        if SSHRDLayout.discover() != nil { return (nil, sshrdError) }
        return (nil, "This HomePod is in DFU, so the SSH ramdisk has to be booted first, but no boot path is set up. "
                + (sshrdError ?? "") + " Legacy fallback: " + (legacyError ?? "unavailable."))
    }

    // MARK: Diagnostics (read-only panic-log + ioreg pull)

    /// Pull diagnostics from a pod in DFU: boot the SSH ramdisk (checkm8 →
    /// ramdisk), THEN forward SSH and pull. For a pod that is already in the
    /// ramdisk use `pullDiagnosticsBooted()` instead.
    func pullDiagnostics(on device: ConnectedDevice) {
        guard let ecid = device.iboot?.ecid else { return }
        let loc = device.locationID
        // FIX (diag-boot): was `makeBooter(ecid:)`, which returns a
        // PreBootedBooter when syscfgBootMode == .preBooted — i.e. straight to
        // iproxy/ssh with the pod still in DFU. Always use a booting booter.
        let (booter, setupError) = makeDFUBooter(ecid: ecid)
        guard let booter else {
            diag = DiagUIState(locationID: loc, ecid: ecid, phase: .bootingRamdisk,
                               log: [], bundle: nil, done: false, error: setupError, running: false)
            return
        }
        let controller = DiagnosticsController(booter: booter)
        diag = DiagUIState(locationID: loc, ecid: ecid, phase: .unlocking,
                           log: [], bundle: nil, done: false, error: nil, running: true)
        diagTask?.cancel()
        diagTask = Task { [weak self] in
            let outcome = await controller.pull(
                ecid: ecid,
                onPhase: { p in Task { @MainActor in self?.diag?.phase = p } },
                onLog: { line in Task { @MainActor in self?.appendDiagLog(line) } })
            await MainActor.run {
                guard var st = self?.diag else { return }
                st.running = false
                switch outcome {
                case .ok(let b): st.bundle = b; st.done = true; st.phase = .done
                case .failed(let msg): st.error = msg
                }
                self?.diag = st
            }
        }
    }

    func dismissDiagnostics() {
        diagTask?.cancel()
        diagTask = nil
        diag = nil
    }

    /// Save a diagnostics bundle into a folder the tech picks.
    func saveDiagnostics(_ bundle: DiagnosticsBundle, serial: String?, to dir: URL) -> String? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = dir.appendingPathComponent("homepod-diag-\(serial ?? "unknown")-\(stamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            if let p = bundle.panicLog, !p.isEmpty {
                try p.write(to: base.appendingPathComponent("paniclog.bin"), options: .atomic)
            }
            if let t = bundle.ioregText, !t.isEmpty {
                try t.data(using: .utf8)?.write(to: base.appendingPathComponent("ioreg.txt"), options: .atomic)
            }
            if let w = bundle.writeProbe, !w.isEmpty {
                try w.data(using: .utf8)?.write(to: base.appendingPathComponent("syscfg-write-probe.txt"), options: .atomic)
            }
            if !bundle.notes.isEmpty {
                try bundle.notes.joined(separator: "\n").data(using: .utf8)?
                    .write(to: base.appendingPathComponent("notes.txt"), options: .atomic)
            }
            return nil
        } catch { return error.localizedDescription }
    }

    private func appendDiagLog(_ line: String) {
        guard var st = diag else { return }
        st.log.append(line)
        if st.log.count > 400 { st.log.removeFirst(st.log.count - 400) }
        diag = st
    }

    func cachedSSHRamdisk() -> URL? {
        let dir = AppPaths.support.appendingPathComponent("SSHRamdisk", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items
            .filter { $0.pathExtension == "img4" && $0.lastPathComponent.hasPrefix("sshrd-") }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    /// The generic A8 APTicket shipped in the app (for checkm8 boot).
    func bundledApticket() -> URL? {
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("apticket-0x7000.shsh")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Find an executable (iproxy, sshpass, …), preferring the copies bundled
    /// inside the app, then the installer's dir, then the standard search paths.
    func locateOnPath(_ name: String) -> URL? {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let bundled = ToolLocator.bundledToolsDirectory { dirs.append(bundled) }
        dirs.append(ToolLocator.userToolsDirectory)
        dirs += ToolEnvironment.searchPaths.map { URL(fileURLWithPath: $0) }
        for d in dirs {
            let u = d.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: u.path) { return u }
        }
        return nil
    }
}
