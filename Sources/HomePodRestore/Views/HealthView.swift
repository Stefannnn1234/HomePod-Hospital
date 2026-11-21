import SwiftUI
import AppKit
import HomePodRestoreCore

struct HealthView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Health Check", subtitle: "Find out whether a HomePod's problem is software (fixable with a restore) or hardware — without erasing it.")
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Text("Two checks you can run").font(.headline)
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Quick check", systemImage: "bolt.fill").font(.callout.weight(.semibold))
                                Text("≈30 seconds. Confirms the USB connection, the chip, and that the HomePod can be unlocked (checkm8). If this fails, it's almost always the adapter, cable or port.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Boot test", systemImage: "cpu").font(.callout.weight(.semibold))
                                Text("2–3 minutes. Boots the HomePod into Apple's restore software and stops — nothing is erased. Failing here points to the A8 processor or memory. Needs firmware selected.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Text("Storage (NAND) is tested during a full restore — if it fails, the Restore screen will say so in plain words.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    BootedPodCard()

                    let dfu = model.devices
                    if dfu.isEmpty {
                        ConnectionGuide()
                    } else {
                        ForEach(dfu) { d in HealthDeviceCard(device: d) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .sheet(item: $model.fullDiag) { state in
            DiagnosticsReportSheet(state: state)
        }
    }
}

struct HealthDeviceCard: View {
    let device: ConnectedDevice
    @EnvironmentObject var model: AppModel

    var body: some View {
        let slot = model.slots.first { $0.locationID == device.locationID }
        if let slot, let job = slot.job, job.snapshot.kind != .restore {
            JobCard(slot: slot, state: job)
        } else {
            Card {
                DeviceHeader(device: device, locationID: device.locationID)
                if let job = slot?.job, job.isRunning {
                    Text("This HomePod is restoring — see the Restore screen.").foregroundStyle(.secondary)
                } else {
                    // Show board health summary if we have a diagnosis for this board
                    if let record = model.healthRecord(for: device),
                       record.assessment != .unknown && record.assessment != .fullyFunctional {
                        BoardHealthSummary(record: record)
                    }

                    HealthChecklist(device: device, snapshot: slot?.job?.snapshot)
                    HStack {
                        Button("Quick check") { model.startJob(.quickCheck, on: device) }
                            .disabled(model.blocker(for: device, kind: .quickCheck) != nil)
                        Button("Boot test") { model.startJob(.bootTest, on: device) }
                            .disabled(model.blocker(for: device, kind: .bootTest) != nil)
                        Button("Pull diagnostics") { model.pullDiagnostics(on: device) }
                            .disabled(device.iboot?.ecid == nil || model.diag?.running == true)
                        Button("Full diagnostics") { model.runFullDiagnostics(on: device) }
                            .disabled(device.mode != .dfu || device.iboot?.ecid == nil || model.fullDiag?.running == true)
                        if let b = model.blocker(for: device, kind: .bootTest) {
                            Text(b).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// Pass / warn / fail list built from what we can see over USB and from the last check.
struct HealthChecklist: View {
    let device: ConnectedDevice?
    let snapshot: RestoreJob.Snapshot?

    enum Result { case pass, warn, fail, unknown }

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let result: Result
    }

    var items: [Item] {
        var out: [Item] = []
        if let d = device {
            out.append(Item(title: "Connected over USB", detail: d.mode.displayName + " on " + d.portLabel, result: .pass))
            switch d.speed {
            case 2?, 3?:
                out.append(Item(title: "USB link", detail: d.speedDescription, result: .pass))
            case 0?, 1?:
                out.append(Item(title: "USB link", detail: d.speedDescription + " — expected high speed. Re-seat the adapter; check the cable.", result: .warn))
            default:
                out.append(Item(title: "USB link", detail: "Speed unknown", result: .unknown))
            }
            if let ib = d.iboot {
                out.append(Item(title: "Processor", detail: ib.isA8 ? "Apple A8 (correct for HomePod)" : "Unexpected chip \(ib.cpid.map { String(format: "0x%X", $0) } ?? "?")",
                                result: ib.isA8 ? .pass : .fail))
                out.append(Item(title: "Logic board", detail: ib.isHomePodBoard ? "HomePod board (b238)" : "Board \(ib.bdid.map { String(format: "0x%X", $0) } ?? "?")",
                                result: ib.isHomePodBoard ? .pass : .warn))
                if let srtg = ib.srtg { out.append(Item(title: "Boot ROM", detail: srtg, result: .pass)) }
            }
        }
        if let s = snapshot {
            switch s.kind {
            case .quickCheck, .bootTest:
                let unlocked = s.phase > .unlocking || s.outcome == .succeeded
                out.append(Item(title: "Unlock (checkm8)",
                                detail: unlocked ? "Unlocked on attempt \(max(s.unlockAttempts, 1))" : (s.outcome == .running ? "Running…" : "Failed — check adapter/cable/port"),
                                result: unlocked ? .pass : (s.outcome == .running ? .unknown : .fail)))
                if s.kind == .bootTest {
                    let booted = s.outcome == .succeeded
                    out.append(Item(title: "Boots restore software",
                                    detail: booted ? "Reached restore mode" : (s.outcome == .running ? "Running…" : (s.primaryIssue?.title ?? "Didn't reach restore mode")),
                                    result: booted ? .pass : (s.outcome == .running ? .unknown : .fail)))
                }
            case .restore:
                if let n = s.hardware.nandWaitSeconds {
                    out.append(Item(title: "Storage (NAND)", detail: "Responded in \(Int(n))s", result: n < 120 ? .pass : .warn))
                }
                if s.issues.contains(where: { $0.category == .hardwareNAND }) {
                    out.append(Item(title: "Storage (NAND)", detail: "Didn't respond during the last restore", result: .fail))
                }
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    icon(item.result).frame(width: 16)
                    Text(item.title).fontWeight(.medium).frame(width: 150, alignment: .leading)
                    Text(item.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private func icon(_ r: Result) -> some View {
        switch r {
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}


// MARK: - Board Health Summary

/// Shows a plain-language hardware health summary for a board with known issues.
struct BoardHealthSummary: View {
    let record: BoardHealthRecord
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Lead with what the user CAN do
            whatYouCanDo

            Divider()

            // Component status rows
            VStack(alignment: .leading, spacing: 8) {
                Text("Hardware status").font(.callout.weight(.semibold))
                statusRow(
                    icon: sepIcon, color: sepColor,
                    title: "Security chip (SEP)",
                    detail: record.sep.explanation
                )
                statusRow(
                    icon: nandIcon, color: nandColor,
                    title: "Storage (NAND)",
                    detail: record.nand.explanation
                )
                statusRow(
                    icon: assessmentIcon, color: assessmentColor,
                    title: "Overall",
                    detail: record.assessment.label
                )
            }

            // Detection notes (collapsible)
            if !record.detectionNotes.isEmpty {
                DisclosureGroup("Detection details") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(record.detectionNotes, id: \.self) { note in
                            Text("- " + note)
                        }
                        Text("Last checked: \(record.lastChecked.formatted(date: .abbreviated, time: .shortened))")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .font(.caption)
            }

            // Clear button
            HStack {
                Spacer()
                Button("Clear diagnosis") {
                    model.clearBoardHealth(ecid: record.ecid)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Remove the stored hardware status for this board (e.g. after a repair)")
            }
        }
    }

    @ViewBuilder private var whatYouCanDo: some View {
        let options = record.bootOptions.filter(\.available)
        if options.isEmpty {
            Label("This board doesn't have any usable options.", systemImage: "xmark.octagon.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.red)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                switch record.assessment {
                case .fullyFunctional:
                    Label("This HomePod is fully functional", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.green)
                case .partiallyFunctional:
                    Label("This HomePod has hardware issues, but can still be used", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                case .partsOnly:
                    Label("This HomePod has major hardware issues", systemImage: "xmark.octagon.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.red)
                case .unknown:
                    Label("Hardware status unknown", systemImage: "questionmark.circle")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }

                if record.assessment != .fullyFunctional && record.assessment != .unknown {
                    Text("Here's what you can do with it:")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(options) { opt in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: opt.icon).foregroundStyle(.green)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(opt.title).font(.callout.weight(.medium))
                                Text(opt.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(title).fontWeight(.medium).frame(width: 150, alignment: .leading)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    // MARK: Icons & colors

    private var sepIcon: String {
        switch record.sep {
        case .unknown: return "circle.dotted"
        case .working: return "checkmark.circle.fill"
        case .dead:    return "xmark.circle.fill"
        }
    }

    private var sepColor: Color {
        switch record.sep {
        case .unknown: return .secondary
        case .working: return .green
        case .dead:    return .red
        }
    }

    private var nandIcon: String {
        switch record.nand {
        case .unknown:  return "circle.dotted"
        case .healthy:  return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .failed:   return "xmark.circle.fill"
        }
    }

    private var nandColor: Color {
        switch record.nand {
        case .unknown:  return .secondary
        case .healthy:  return .green
        case .degraded: return .orange
        case .failed:   return .red
        }
    }

    private var assessmentIcon: String {
        switch record.assessment {
        case .unknown:             return "circle.dotted"
        case .fullyFunctional:     return "checkmark.circle.fill"
        case .partiallyFunctional: return "exclamationmark.triangle.fill"
        case .partsOnly:           return "xmark.octagon.fill"
        }
    }

    private var assessmentColor: Color {
        switch record.assessment {
        case .unknown:             return .secondary
        case .fullyFunctional:     return .green
        case .partiallyFunctional: return .orange
        case .partsOnly:           return .red
        }
    }
}


/// For a HomePod already booted into the SSH ramdisk (not in DFU, so the USB
/// scanner can't list it): pull diagnostics or read SysCfg over SSH directly.
struct BootedPodCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(Color.accentColor)
                Text("Already booted into the SSH ramdisk?").font(.headline)
            }
            Text("For a HomePod already booted into the ramdisk (not in DFU). If you booted it manually via SSHRD and iproxy is forwarding, connect here. DFU pods should use the buttons on their own card — those will boot the ramdisk automatically.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { model.pullDiagnosticsBooted() } label: {
                    Label("Pull diagnostics", systemImage: "stethoscope")
                }
                .buttonStyle(.borderedProminent)
                Button { model.runFullDiagnosticsBooted() } label: {
                    Label("Full diagnostics", systemImage: "list.clipboard")
                }
                .buttonStyle(.bordered)
                if model.showAdvanced {
                    Button { model.readSysCfgBooted() } label: {
                        Label("Read SysCfg", systemImage: "number.square")
                    }
                    Button { pickAndRestoreBooted() } label: {
                        Label("Restore SysCfg…", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Text("Read-only diagnostics are always available. Read SysCfg appears with Advanced enabled.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pickAndRestoreBooted() {
        let panel = NSOpenPanel()
        panel.title = "Choose a SysCfg dump"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.restoreSysCfgBooted(from: url)
        }
    }
}
