import SwiftUI
import AppKit
import HomePodRestoreCore

/// Read, save, and restore a HomePod's per-unit SysCfg over the SSH ramdisk.
/// Read is the de-risk step; restore writes a saved dump verbatim to a swapped
/// chip (and verifies it read back identical).
struct SysCfgSheet: View {
    let state: SysCfgUIState
    /// Live state (the sheet item is only a presentation snapshot).
    private var current: SysCfgUIState { model.syscfg ?? state }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    private var device: ConnectedDevice? { model.devices.first { $0.locationID == current.locationID } }
    private var title: String { current.kind == .restore ? "Restore SysCfg" : "Read SysCfg" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "number.square").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title2.weight(.semibold))
                    Text("HomePod • ID \(current.ecidShort)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Banner(icon: "flask.fill",
                   text: "Experimental. Works with the unit's own serial and MAC addresses so a NAND swap keeps its original identity. It does not touch Activation Lock.",
                   tint: .purple)

            if current.running {
                runningView
            } else if let err = current.error {
                errorView(err)
            } else if current.done {
                if current.kind == .read, let d = current.dump {
                    readResultView(d)
                } else if current.kind == .restore {
                    restoreDoneView(current.dump)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { model.dismissSysCfg(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 500)
    }

    // MARK: running

    @ViewBuilder private var runningView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(current.phase.title).font(.headline)
        }
        if (model.syscfgBootMode == .sshrd || model.syscfgBootMode == .diags) && current.phase <= .connecting {
            Text("The HomePod should be right-side up for this. If it's still upside down, turn it over now.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if current.kind == .restore, let d = current.dump {
            Text("Writing serial \(d.serialNumber ?? "?"), Wi-Fi \(d.wifiMAC ?? "?"), BT \(d.bluetoothMAC ?? "?") — then reading back to verify.")
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

    // MARK: error (incl. "need to build the ramdisk")

    @ViewBuilder private func errorView(_ message: String) -> some View {
        Label(current.kind == .restore ? "Couldn't restore SysCfg" : "Couldn't read SysCfg", systemImage: "xmark.octagon.fill")
            .font(.headline).foregroundStyle(.red)
        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)

        // If the tried-to-restore dump is shown, surface its fields so the tech
        // can see what was rejected.
        if current.kind == .restore, let d = current.dump {
            fieldBox(d)
        }

        if message.contains("No SSH ramdisk") {
            if let b = model.sshRamdiskBuild {
                sshBuildProgress(b)
            } else {
                Button { model.buildDefaultSSHRamdisk(forPod: device) } label: {
                    Label("Build SSH ramdisk", systemImage: "hammer")
                }
                .buttonStyle(.borderedProminent)
                Text("One-time: builds a shell ramdisk from the Apple TV donor. Needs the builder tools (Setup → Install tools).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        // SSHRD-mode: no built ramdisk in the SSHRD checkout — offer to build it.
        if message.contains("no built ramdisk") {
            if let b = model.sshrdBuild {
                sshrdBuildProgress(b)
            } else {
                Button { model.buildSSHRDRamdisk() } label: {
                    Label("Build SSH ramdisk (SSHRD)", systemImage: "hammer")
                }
                .buttonStyle(.borderedProminent)
                Text("Runs the proven SSHRD create step (sshrd.sh ota 18.3). The HomePod must be in DFU and connected while it builds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func sshrdBuildProgress(_ b: SSHRDBuildState) -> some View {
        Divider()
        if let finished = b.finished {
            Label("SSH ramdisk built", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text(finished.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            Text("Close this and try again.").font(.callout)
        } else if let err = b.error {
            Label("Build failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text(err).font(.callout).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Building the SSH ramdisk…").font(.callout) }
            if let last = b.log.last {
                Text(last).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func sshBuildProgress(_ b: SSHRamdiskBuildState) -> some View {
        Divider()
        if let finished = b.finished {
            Label("SSH ramdisk built", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text(finished.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Close this and try again.").font(.callout)
        } else if let err = b.error {
            Label("Build failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            Text(err).font(.callout).fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                ProgressView(value: b.update.progress).frame(maxWidth: 200)
                Text(b.update.stage.title).font(.callout)
            }
            Text(b.update.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: read result

    @ViewBuilder private func readResultView(_ data: SysCfgData) -> some View {
        Label(data.looksValid ? "SysCfg read" : "Read \(data.rawBytes.count) bytes (no recognizable SysCfg signature)",
              systemImage: data.looksValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.headline).foregroundStyle(data.looksValid ? .green : .orange)

        fieldBox(data)

        Text("Compare the serial above to the sticker on the unit. If it matches, the read path works and this same dump can be written to a replacement chip.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        HStack {
            Button { saveDump(data) } label: { Label("Save dump…", systemImage: "square.and.arrow.down") }
            if !data.hasEssentials {
                Text("Missing some identity fields — not safe to use for a restore.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: restore done

    @ViewBuilder private func restoreDoneView(_ data: SysCfgData?) -> some View {
        Label("SysCfg restored & verified", systemImage: "checkmark.seal.fill")
            .font(.headline).foregroundStyle(.green)
        if let data { fieldBox(data) }
        Text("The replacement chip now carries the unit's original identity, and read back identical to the dump. Unplug power to leave the ramdisk.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: shared field box

    private func fieldBox(_ data: SysCfgData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldRow("Serial number", data.serialNumber)
            fieldRow("Wi-Fi MAC", data.wifiMAC)
            fieldRow("Bluetooth MAC", data.bluetoothMAC)
            if data.mlbSerial != nil { fieldRow("MLB serial", data.mlbSerial) }
            if data.region != nil { fieldRow("Region", data.region) }
            fieldRow("Dump size", "\(data.rawBytes.count) bytes")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func fieldRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value ?? "—").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func saveDump(_ data: SysCfgData) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "syscfg-\(data.serialNumber ?? current.ecidShort.replacingOccurrences(of: "…", with: "")).bin"
        panel.canCreateDirectories = true
        panel.title = "Save SysCfg dump"
        if panel.runModal() == .OK, let url = panel.url {
            if let err = model.writeDump(data.rawBytes, to: url) {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the dump"
                alert.informativeText = err
                alert.runModal()
            }
        }
    }
}
