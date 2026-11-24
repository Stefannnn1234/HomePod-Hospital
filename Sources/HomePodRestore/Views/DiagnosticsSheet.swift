import SwiftUI
import AppKit
import HomePodRestoreCore

/// Read-only diagnostics pull: boot the SSH ramdisk and copy the panic log +
/// an ioreg snapshot off the pod to help troubleshoot. No writes, no risk.
struct DiagnosticsSheet: View {
    let state: DiagUIState
    private var current: DiagUIState { model.diag ?? state }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    private var device: ConnectedDevice? { model.devices.first { $0.locationID == current.locationID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pull diagnostics").font(.title2.weight(.semibold))
                    Text("HomePod • ID \(current.ecidShort)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Banner(icon: "lock.shield",
                   text: "Read-only. Boots the SSH ramdisk and copies the panic log and an ioreg snapshot off the pod. It never writes to the HomePod.",
                   tint: .teal)

            if current.running {
                runningView
            } else if let err = current.error {
                errorView(err)
            } else if current.done, let b = current.bundle {
                resultView(b)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { model.dismissDiagnostics(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 500)
    }

    @ViewBuilder private var runningView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(current.phase.title).font(.headline)
        }
        if (model.syscfgBootMode == .sshrd || model.syscfgBootMode == .diags) && current.phase <= .connecting {
            Text("The HomePod should be right-side up for this. If it's still upside down, turn it over now.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        logTail
    }

    private var logTail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(current.log.suffix(200).enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }.padding(8)
            }
            .frame(minHeight: 150)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: current.log.count) { _ in proxy.scrollTo(min(current.log.count, 200) - 1, anchor: .bottom) }
        }
    }

    @ViewBuilder private func errorView(_ message: String) -> some View {
        Label("Couldn't pull diagnostics", systemImage: "xmark.octagon.fill")
            .font(.headline).foregroundStyle(.red)
        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func resultView(_ bundle: DiagnosticsBundle) -> some View {
        Label("Diagnostics pulled", systemImage: "checkmark.circle.fill")
            .font(.headline).foregroundStyle(.green)

        VStack(alignment: .leading, spacing: 6) {
            row("Panic log", bundle.panicLog.map { "\($0.count) bytes" } ?? "none")
            row("ioreg snapshot", bundle.ioregText.map { "\($0.count) chars" } ?? "none")
            row("SysCfg write probe", bundle.writeProbe.map { "\($0.count) chars" } ?? "none")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

        if let raw = bundle.panicLog, let panic = PanicLogReport.decode(raw) {
            panicView(panic)
        }

        if !bundle.notes.isEmpty {
            ForEach(Array(bundle.notes.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }

        if (bundle.panicLog?.isEmpty ?? true) && (bundle.ioregText?.isEmpty ?? true) {
            Text("Nothing to save — an empty panic device usually means the pod hasn't panicked (a good sign).")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button { save(bundle) } label: { Label("Save diagnostics…", systemImage: "square.and.arrow.down") }
        }
    }

    /// The saved panic, decoded: its `panic(...)` line up front, the rest folded.
    @ViewBuilder private func panicView(_ panic: PanicLogReport) -> some View {
        Label("This pod has panicked before", systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold)).foregroundStyle(.orange)
        Text(panic.headline)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(Array(panic.notes.enumerated()), id: \.offset) { _, note in
            Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Full panic log") {
            ScrollView {
                Text(panic.panicText + (panic.otherLog.map { "\n\n--- later console output ---\n" + $0 } ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func save(_ bundle: DiagnosticsBundle) {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the diagnostics"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let dir = panel.url {
            let serial = device?.iboot?.srnm
            if let err = model.saveDiagnostics(bundle, serial: serial, to: dir) {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the diagnostics"
                alert.informativeText = err
                alert.runModal()
            }
        }
    }
}
