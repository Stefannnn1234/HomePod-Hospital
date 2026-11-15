import SwiftUI
import AppKit
import HomePodRestoreCore

/// Sheet for a full-diagnostics run: live progress while the tools run, then
/// the report. Presented with `.sheet(item: $model.fullDiag)`.
struct DiagnosticsReportSheet: View {
    let state: FullDiagUIState
    /// Live state (the sheet item is only a presentation snapshot).
    private var current: FullDiagUIState { model.fullDiag ?? state }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    private var subtitle: String {
        if let serial = current.report?.serial { return "HomePod • \(serial)" }
        return current.ecid == 0 ? "HomePod • booted into the ramdisk" : "HomePod • ID \(current.ecidShort)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checklist").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Full Diagnostics").font(.title2.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if current.running {
                runningView
            } else if let err = current.error {
                Label("Couldn't run diagnostics", systemImage: "xmark.octagon.fill")
                    .font(.headline).foregroundStyle(.red)
                Text(err).font(.callout).fixedSize(horizontal: false, vertical: true)
                if !current.log.isEmpty { logTail }
            } else if let report = current.report {
                DiagnosticsReportView(report: report)
            }

            Spacer(minLength: 0)
            HStack {
                if !current.running {
                    Text("Read-only — nothing was written to the HomePod.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(current.running ? "Cancel" : "Done") { model.dismissFullDiagnostics(); dismiss() }
                    .keyboardShortcut(current.running ? .cancelAction : .defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 620)
    }

    // MARK: running

    @ViewBuilder private var runningView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(runningTitle).font(.headline)
        }
        if let p = current.progress {
            ProgressView(value: p.fraction)
            Text("Check \(min(p.index + 1, p.total)) of \(p.total)")
                .font(.caption).foregroundStyle(.secondary)
        } else if (model.syscfgBootMode == .sshrd || model.syscfgBootMode == .diags) && current.phase <= .connecting {
            Text("If the HomePod is upside down for DFU, flip it upright once you see boot activity below.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        logTail
    }

    private var runningTitle: String {
        if current.phase == .working, let p = current.progress { return "Checking: \(p.tool.title)" }
        return current.phase.title
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
}

/// The report itself: overall verdict banner, then one group per subsystem.
/// Self-contained, so it can also be embedded outside the sheet.
struct DiagnosticsReportView: View {
    let report: FullDiagnosticsReport
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            verdictBanner

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DiagSubsystem.allCases) { subsystem in
                        let rows = report.rows(in: subsystem)
                        if !rows.isEmpty {
                            DiagSubsystemGroup(subsystem: subsystem, verdict: report.verdict(in: subsystem), rows: rows)
                        }
                    }
                    if let calibration = report.factoryCalibration {
                        FactoryCalibrationSection(calibration: calibration)
                    }
                }
                .padding(.trailing, 4)
            }

            HStack {
                Button { exportJSON() } label: { Label("Export JSON…", systemImage: "square.and.arrow.down") }
                Button { copySupportInfo() } label: {
                    Label(copied ? "Copied" : "Copy support info", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
                Text(report.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: banner

    private var verdictBanner: some View {
        let tint = report.overall.tint
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.overall.bannerSymbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.headline).font(.headline)
                Text(bannerDetail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
    }

    private var bannerDetail: String {
        var parts: [String] = []
        let findings = report.findings
        if !findings.isEmpty {
            parts.append(findings.prefix(3).map { "\($0.label): \($0.value)" }.joined(separator: " · "))
            if findings.count > 3 { parts.append("and \(findings.count - 3) more below") }
        }
        let skipped = report.incomplete
        if !skipped.isEmpty {
            parts.append("\(skipped.count) check\(skipped.count == 1 ? "" : "s") couldn't run (\(skipped.map(\.title).joined(separator: ", ")))")
        }
        if parts.isEmpty {
            parts.append("Serial \(report.serial ?? "not readable"). These are ramdisk checks — sound, microphones and the tap sensor can't be exercised from here.")
        }
        return parts.joined(separator: ". ") + (parts.last?.hasSuffix(".") == true ? "" : ".")
    }

    // MARK: actions

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = report.suggestedFileName + ".json"
        panel.canCreateDirectories = true
        panel.title = "Export diagnostics report"
        if panel.runModal() == .OK, let url = panel.url {
            if let err = model.saveFullDiagnostics(report, to: url) {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the report"
                alert.informativeText = err
                alert.runModal()
            }
        }
    }

    private func copySupportInfo() {
        model.copyToClipboard(model.fullDiagnosticsSupportText(report))
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

/// One subsystem's rows in a rounded box, with the group's verdict in the header.
private struct DiagSubsystemGroup: View {
    let subsystem: DiagSubsystem
    let verdict: DiagVerdict
    let rows: [DiagRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: subsystem.symbol).foregroundStyle(.secondary)
                Text(subsystem.title).font(.headline)
                Spacer()
                DiagVerdictIcon(verdict: verdict)
            }
            Divider()
            ForEach(rows) { row in DiagRowView(row: row) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Factory calibration: what this unit carries in SysCfg against what a
/// factory-calibrated HomePod has (calibration keys, driver and microphone
/// counts, payload layout). Its verdict is its own — it is not part of the
/// banner, because the Factory group already reports missing tags.
private struct FactoryCalibrationSection: View {
    let calibration: FactoryCalibrationReport
    @State private var showValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                Text(FactoryCalibrationReport.title).font(.headline)
                Spacer()
                DiagVerdictIcon(verdict: calibration.verdict)
            }
            Text("A factory unit has \(FactoryCalibrationExpectation.layoutSummary).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(calibration.rows) { row in DiagRowView(row: row) }
            if let unit = calibration.unit, !unit.drivers.isEmpty {
                DisclosureGroup(isExpanded: $showValues) {
                    FactoryCalibrationValues(unit: unit)
                } label: {
                    Text("Per-driver values").font(.callout)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// The decoded calibration, one driver per block: overall gain, then each EQ
/// band as filter shape, frequency, gain and bandwidth.
private struct FactoryCalibrationValues: View {
    let unit: PuffinUnitCalibration

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(unit.drivers) { driver in
                HStack(alignment: .top, spacing: 8) {
                    Text(driver.role.title).fontWeight(.medium).frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("overall \(driver.overallGainRaw)")
                        ForEach(driver.bands, id: \.index) { band in
                            Text(band.summary)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
            if !unit.micGainsRaw.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("Mic trims").fontWeight(.medium).frame(width: 90, alignment: .leading)
                    Text(unit.micGainsRaw.map { String($0) }.joined(separator: "  "))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
            Text("LS = low shelf, HS = high shelf, PEQ = parametric. Frequencies are in Hz. Gain (dB) and bandwidth are the stored integers divided by 100 — that scale is inferred, not documented. \"overall\" and the mic trims are shown exactly as stored.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// One row: icon, label, value, and the optional explanation underneath.
private struct DiagRowView: View {
    let row: DiagRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DiagVerdictIcon(verdict: row.verdict).frame(width: 16)
            Text(row.label).fontWeight(.medium).frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let note = row.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// Pass / warn / fail / info icon — same symbols and colours as `HealthChecklist`.
struct DiagVerdictIcon: View {
    let verdict: DiagVerdict

    var body: some View {
        Image(systemName: verdict.symbol)
            .foregroundStyle(verdict.tint)
            .help(verdict.helpText)
    }
}

private extension DiagVerdict {
    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    var bannerSymbol: String {
        switch self {
        case .pass: return "checkmark.seal.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .info: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .info: return .secondary
        }
    }

    var helpText: String {
        switch self {
        case .pass: return "Passed"
        case .warn: return "Needs a closer look"
        case .fail: return "Failed"
        case .info: return "For information — not judged"
        }
    }
}

private extension DiagSubsystem {
    var symbol: String {
        switch self {
        case .storage: return "internaldrive"
        case .factory: return "number.square"
        case .environment: return "thermometer.medium"
        case .audio: return "hifispeaker"
        case .sensors: return "mic"
        }
    }
}
