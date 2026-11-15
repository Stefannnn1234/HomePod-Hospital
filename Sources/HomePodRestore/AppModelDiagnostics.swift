import Foundation
import HomePodRestoreCore

// MARK: - Full diagnostics ("Run full diagnostics")
//
// Same shape as the SysCfg read and the diagnostics pull in
// AppModelSysCfg.swift: build a controller, publish a UI-state struct, run the
// work in a Task, and hop back to the main actor for every state change.
//
// Wired in: `fullDiag` / `fullDiagTask` live in AppModel.swift, the buttons are
// in HealthView.swift (`HealthDeviceCard` for a pod in DFU, `BootedPodCard` for
// one already in the ramdisk), and HealthView presents `DiagnosticsReportSheet`.

/// UI state for a full-diagnostics run shown in `DiagnosticsReportSheet`.
struct FullDiagUIState: Identifiable {
    var id: UInt32 { locationID }
    var locationID: UInt32
    var ecid: UInt64
    var phase: SysCfgPhase
    var log: [String]
    /// The tool currently running (or the last one that finished).
    var progress: FullDiagnosticsController.Progress?
    var report: FullDiagnosticsReport?
    var done: Bool
    var error: String?
    var running: Bool

    var ecidShort: String { "…" + String(format: "%016llX", ecid).suffix(6) }
}

@MainActor
extension AppModel {

    // MARK: Run on a pod in DFU (the app boots the ramdisk)

    func runFullDiagnostics(on device: ConnectedDevice) {
        guard let ecid = device.iboot?.ecid else { return }
        let loc = device.locationID

        // A pod on this card is in DFU, so the ramdisk has to be BOOTED first.
        // `makeBooter(ecid:)` would hand back a PreBootedBooter (iproxy + ssh
        // only, no checkm8, no boot) whenever the boot-mode setting is "already
        // booted" — which is the default without an SSHRD checkout. Always use
        // the booting booter here, exactly like `pullDiagnostics(on:)`.
        let (maybeBooter, setupError) = makeDFUBooter(ecid: ecid)
        guard let booter = maybeBooter else {
            fullDiag = FullDiagUIState(locationID: loc, ecid: ecid, phase: .bootingRamdisk, log: [], progress: nil,
                                       report: nil, done: false, error: setupError, running: false)
            return
        }

        fullDiag = FullDiagUIState(locationID: loc, ecid: ecid, phase: .unlocking, log: [], progress: nil,
                                   report: nil, done: false, error: nil, running: true)
        startFullDiagnostics(FullDiagnosticsController(booter: booter, scripts: bundledDiagScripts()), ecid: ecid)
    }

    // MARK: Run on a pod already booted into the ramdisk
    //
    // Not a DFU device, so the USB scanner can't list it — same sentinel
    // location/ecid convention as `pullDiagnosticsBooted()`.

    func runFullDiagnosticsBooted() {
        fullDiag = FullDiagUIState(locationID: 0, ecid: 0, phase: .connecting, log: [], progress: nil,
                                   report: nil, done: false, error: nil, running: true)
        let cfg = PreBootedBooter.Config(sshTool: URL(fileURLWithPath: "/usr/bin/ssh"),
                                         sshpass: bestSSHpass())
        let controller = FullDiagnosticsController(booter: PreBootedBooter(config: cfg, forwarder: bestIproxy()),
                                                   scripts: bundledDiagScripts())
        startFullDiagnostics(controller, ecid: 0)
    }

    private func startFullDiagnostics(_ controller: FullDiagnosticsController, ecid: UInt64) {
        fullDiagTask?.cancel()
        fullDiagTask = Task { [weak self] in
            let outcome = await controller.run(
                ecid: ecid,
                onPhase: { p in Task { @MainActor in self?.fullDiag?.phase = p } },
                onLog: { line in Task { @MainActor in self?.appendFullDiagLog(line) } },
                onProgress: { p in Task { @MainActor in self?.fullDiag?.progress = p } })
            await MainActor.run {
                guard var st = self?.fullDiag else { return }
                st.running = false
                switch outcome {
                case .ok(let report): st.report = report; st.done = true; st.phase = .done
                case .failed(let msg): st.error = msg
                }
                self?.fullDiag = st
            }
        }
    }

    func dismissFullDiagnostics() {
        fullDiagTask?.cancel()
        fullDiagTask = nil
        fullDiag = nil
    }

    // MARK: Export / support

    /// Write the report as JSON to a file the tech chooses. Returns an error
    /// message, or nil on success (same convention as `writeDump`).
    func saveFullDiagnostics(_ report: FullDiagnosticsReport, to url: URL) -> String? {
        do {
            try report.exportJSON().write(to: url, options: .atomic)
            return nil
        } catch { return error.localizedDescription }
    }

    /// Plain-text summary for a support chat. Serial and MAC addresses are
    /// shortened so it is safe to paste publicly.
    func fullDiagnosticsSupportText(_ report: FullDiagnosticsReport) -> String {
        report.supportText(appVersion: appVersion)
    }

    // MARK: Helpers

    /// The `hpdiag-*` scripts shipped with the app (the overlay's
    /// usr/local/bin — in the .app that is
    /// Contents/Resources/ssh-ramdisk-overlay/usr/local/bin). The controller
    /// pushes them to a pod whose ramdisk was built without them, so a script
    /// change never needs a ramdisk rebuild. Empty when the overlay isn't
    /// there; diagnostics then rely on what the ramdisk carries.
    func bundledDiagScripts() -> [DiagScript] {
        let dir = SSHRamdiskBuilder.overlayDirectory.appendingPathComponent("usr/local/bin", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasPrefix("hpdiag-") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)), !data.isEmpty else { return nil }
            return DiagScript(name: name, content: data)
        }
    }

    private func appendFullDiagLog(_ line: String) {
        guard var st = fullDiag else { return }
        st.log.append(line)
        if st.log.count > 400 { st.log.removeFirst(st.log.count - 400) }
        fullDiag = st
    }
}
