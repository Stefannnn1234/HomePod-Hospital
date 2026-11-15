import SwiftUI
import AppKit
import HomePodRestoreCore

struct DeviceCard: View {
    let slot: Slot
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let job = slot.job {
            JobCard(slot: slot, state: job)
        } else if let device = slot.device {
            IdleDeviceCard(device: device)
        }
    }
}

/// Header line shared by all card states.
struct DeviceHeader: View {
    let device: ConnectedDevice?
    let locationID: UInt32
    var jobRunning = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hifispeaker.fill").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("HomePod").font(.headline)
                HStack(spacing: 6) {
                    if let d = device {
                        Text(d.mode.displayName)
                        Text("•")
                        Text(d.portLabel)
                    } else {
                        Text(jobRunning ? "Reconnecting… (normal during a restore)" : "Unplugged")
                    }
                    if let ecid = device?.iboot?.ecid {
                        Text("•")
                        Text("ID …" + String(format: "%016llX", ecid).suffix(6))
                            .help("ECID " + String(format: "0x%016llX", ecid))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Idle (connected, nothing running)

struct IdleDeviceCard: View {
    let device: ConnectedDevice
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            DeviceHeader(device: device, locationID: device.locationID)
            switch device.mode {
            case .dfu:
                dfuContent
            case .recovery:
                Text("This HomePod is in recovery mode.").font(.callout)
                Text("Unplug HomePod power, wait a few seconds, then plug power back in (keep USB connected). It should come back in DFU mode.")
                    .font(.callout).foregroundStyle(.secondary)
            case .restore, .unknown:
                Text("This HomePod is running (not in DFU mode).").font(.callout)
                Text("To restore it: unplug power, make sure it's upside down with the adapter attached and USB connected, then plug power back in.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func pickAndRestoreSysCfg(_ device: ConnectedDevice) {
        let panel = NSOpenPanel()
        panel.title = "Choose a SysCfg dump"
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.restoreSysCfg(on: device, from: url)
        }
    }

    @ViewBuilder private var dfuContent: some View {
        let ib = device.iboot
        if let ib, !ib.isA8 {
            Label("This doesn't look like a 1st-gen HomePod (chip \(ib.cpid.map { String(format: "0x%X", $0) } ?? "?")). This app only restores the original HomePod.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        } else {
            if device.speed == 0 || device.speed == 1 {
                Label("Connected at USB full speed. That usually means the adapter isn't sitting flat — the restore may fail. Try re-seating it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            let blocker = model.blocker(for: device, kind: .restore)
            Text(blocker ?? "Ready to restore. This erases the HomePod and installs \(model.selectedFirmware?.info.productVersion ?? "the selected") software.")
                .font(.callout)
                .foregroundStyle(blocker == nil ? Color.primary : Color.orange)
            HStack {
                Button {
                    model.startJob(.restore, on: device)
                } label: {
                    Label("Restore", systemImage: "arrow.counterclockwise")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(blocker != nil)

                Menu("Check health") {
                    Button("Quick check (30 seconds)") { model.startJob(.quickCheck, on: device) }
                        .disabled(model.blocker(for: device, kind: .quickCheck) != nil)
                    Button("Boot test — doesn't erase (2–3 minutes)") { model.startJob(.bootTest, on: device) }
                        .disabled(model.blocker(for: device, kind: .bootTest) != nil)
                    Divider()
                    Button("Pull diagnostics (panic log)…") { model.pullDiagnostics(on: device) }
                        .disabled(model.blocker(for: device, kind: .quickCheck) != nil)
                    if model.showAdvanced {
                        Divider()
                        Picker("Boot mode", selection: $model.syscfgBootMode) {
                            ForEach(SysCfgBootMode.allCases.filter(\.isVisible)) { Text($0.title).tag($0) }
                        }
                        Text(model.syscfgBootMode.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.syscfgBootMode.usesSSH {
                            Button("Read SysCfg (SSH)") { model.readSysCfg(on: device) }
                                .disabled(model.blocker(for: device, kind: .quickCheck) != nil)
                            Button("Restore SysCfg from dump…") { pickAndRestoreSysCfg(device) }
                                .disabled(model.blocker(for: device, kind: .quickCheck) != nil)
                        } else {
                            Button("Boot Factory DIAGS") { model.bootFactoryDiags(on: device) }
                                .disabled(model.blocker(for: device, kind: .quickCheck) != nil)
                            Text("After DIAGS boots, open DIAGS Shell in the sidebar\nand connect your USB-to-serial adapter.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize()
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Job running / finished

struct JobCard: View {
    let slot: Slot
    @ObservedObject var state: JobState
    @EnvironmentObject var model: AppModel
    @State private var showLog = false
    @State private var confirmCancel = false
    @State private var copied = false

    private var snap: RestoreJob.Snapshot { state.snapshot }

    var body: some View {
        Card(tint: tint) {
            DeviceHeader(device: slot.device, locationID: slot.locationID, jobRunning: state.isRunning)
            switch snap.outcome {
            case .running: running
            case .succeeded: succeeded
            case .failed(_, let message): failed(message)
            case .cancelled: cancelled
            }
            HStack {
                Button { showLog = true } label: { Label("Log", systemImage: "text.alignleft") }
                Button {
                    model.copyToClipboard(model.supportReport(for: slot))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: { Label(copied ? "Copied!" : "Copy support info", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Spacer()
                if state.isRunning {
                    Button("Stop", role: .destructive) { confirmCancel = true }
                } else {
                    if slot.device?.mode == .dfu {
                        if snap.kind != .restore {
                            Button("Restore now") { model.retry(slot, as: .restore) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button(snap.outcome == .succeeded ? "Run again" : "Try again") { model.retry(slot) }
                    }
                    Button("Dismiss") { model.dismiss(slot) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .sheet(isPresented: $showLog) { LogSheet(slot: slot, state: state) }
        .confirmationDialog("Stop this \(snap.kind.title.lowercased())?", isPresented: $confirmCancel) {
            Button("Stop", role: .destructive) { model.cancel(state) }
        } message: {
            Text("The HomePod won't be damaged, but you'll need to start over.")
        }
    }

    private var tint: Color? {
        switch snap.outcome {
        case .succeeded: return .green
        case .failed: return .red
        default: return nil
        }
    }

    // MARK: running

    @ViewBuilder private var running: some View {
        HStack {
            Text(snap.kind == .restore ? snap.phase.title : snap.kind.title).font(.title3.weight(.semibold))
            Spacer()
            Text(elapsed).monospacedDigit().foregroundStyle(.secondary).font(.caption)
        }
        if snap.phase == .waiting, let fw = state.job.firmware, let p = model.preparing[fw.id] {
            ProgressView(value: p)
            Text("Unpacking firmware — one time only, about a minute (\(Int(p * 100))%)")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ProgressView(value: snap.overallProgress)
            Text(snap.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        if snap.kind != .quickCheck {
            PhaseChecklist(snapshot: snap)
        }
        if snap.phase >= .booting {
            Label("Don't touch the HomePod, adapter or cable until this finishes.", systemImage: "hand.raised.fill")
                .font(.caption).foregroundStyle(.orange)
        }
        let notes = snap.issues.filter { $0.severity == .normal }
        if !notes.isEmpty {
            ForEach(notes) { n in
                Label("\(n.title): \(n.explanation)", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var elapsed: String {
        let end = snap.finishedAt ?? Date()
        return ByteFormat.duration(end.timeIntervalSince(snap.startedAt))
    }

    // MARK: finished

    @ViewBuilder private var succeeded: some View {
        switch snap.kind {
        case .restore:
            Label("Restore complete!", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.green)
            Text("It may look like it's boot-looping right now — that's expected. Finish up in this order:")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label("Unplug power from the HomePod", systemImage: "1.circle.fill")
                Label("Unplug the USB cable", systemImage: "2.circle.fill")
                Label("Remove the adapter", systemImage: "3.circle.fill")
                Label("Flip it right-side up, plug in power, and set it up in the Home app", systemImage: "4.circle.fill")
            }
            .font(.callout)
            Text("Tip: after setup, let the HomePod update itself from the Home app.")
                .font(.caption).foregroundStyle(.secondary)
            HardwareSummary(hardware: snap.hardware)
        case .quickCheck:
            Label("Quick check passed", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.green)
            HealthChecklist(device: slot.device, snapshot: snap)
        case .bootTest:
            Label("Boot test passed", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.green)
            HealthChecklist(device: slot.device, snapshot: snap)
            Text("Nothing was erased. Unplug power to leave restore mode.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func failed(_ message: String) -> some View {
        let issue = snap.primaryIssue
        Label(issue?.title ?? "Something went wrong", systemImage: "xmark.octagon.fill")
            .font(.title3.weight(.semibold)).foregroundStyle(.red)
        Text(issue?.explanation ?? message).font(.callout)
        if let issue, !issue.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("What to try:").font(.callout.weight(.semibold))
                ForEach(Array(issue.suggestions.enumerated()), id: \.offset) { _, s in
                    Label(s, systemImage: "arrow.right.circle").font(.callout)
                }
            }
        }
        if issue?.isHardware == true {
            HStack {
                Image(systemName: "wrench.adjustable.fill")
                Text("Looks like a hardware problem.")
                Link("Nic's Fix can repair it →", destination: Links.website)
            }
            .font(.callout)
        }
        Text("Stopped at: \(snap.phase.title)").font(.caption).foregroundStyle(.secondary)
        HStack {
            Text("Still stuck?").font(.caption)
            Link("Ask on Discord", destination: model.discordURL).font(.caption)
            Text("— click “Copy support info” and paste it in your message.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cancelled: some View {
        Label("Stopped", systemImage: "stop.circle.fill").font(.title3.weight(.semibold))
        Text("Unplug power, then USB. Reconnect (USB first, then power) to try again.")
            .font(.callout).foregroundStyle(.secondary)
    }
}

/// ✓/• list of the restore steps.
struct PhaseChecklist: View {
    let snapshot: RestoreJob.Snapshot

    var steps: [RestorePhase] {
        snapshot.kind == .bootTest ? [.unlocking, .preparing, .booting] : RestorePhase.visibleSteps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps, id: \.self) { p in
                HStack(spacing: 8) {
                    if p < snapshot.phase {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if p == snapshot.phase {
                        ProgressView().controlSize(.mini).frame(width: 14)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                    }
                    Text(p.title)
                        .foregroundStyle(p > snapshot.phase ? .secondary : .primary)
                    if p == snapshot.phase, let pp = snapshot.phaseProgress {
                        Text("\(Int(pp * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
    }
}

struct HardwareSummary: View {
    let hardware: HardwareInfo
    var body: some View {
        if !hardware.isEmpty {
            DisclosureGroup("Hardware details") {
                VStack(alignment: .leading, spacing: 2) {
                    if let b = hardware.boardID { Text("Board ID: \(b)\(b == 56 ? " (HomePod)" : "")") }
                    if let c = hardware.chipID { Text("Chip ID: \(c)\(c == 0x7000 ? " (A8)" : "")") }
                    if let p = hardware.productionMode { Text("Production mode: \(p ? "yes" : "no")") }
                    if let n = hardware.nandWaitSeconds { Text("Storage (NAND) responded in \(Int(n))s") }
                }
                .font(.caption.monospaced())
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }
}

struct LogSheet: View {
    let slot: Slot
    @ObservedObject var state: JobState
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(state.snapshot.kind.title) log").font(.title2.weight(.semibold))
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.snapshot.logURL]) }
                Button("Copy support info") { model.copyToClipboard(model.supportReport(for: slot)) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Repeated “ReverseProxy” and “No data to read” lines are normal.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.snapshot.recentLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onAppear { proxy.scrollTo(state.snapshot.recentLines.count - 1, anchor: .bottom) }
                .onChange(of: state.snapshot.recentLines.count) { n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("ERROR") { return .red }
        if line.hasPrefix("Status:") || line.hasSuffix(")") && line.first?.isUppercase == true { return .accentColor }
        return .primary
    }
}
