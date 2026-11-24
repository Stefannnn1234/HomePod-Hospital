import SwiftUI
import AppKit
import HomePodRestoreCore

/// "Check flash (NAND) health" for a pod that's running its normal software.
struct NANDHealthSection: View {
    let device: ConnectedDevice
    @EnvironmentObject var model: AppModel

    var body: some View {
        let state = model.nandHealth[device.locationID]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.readNANDHealth(on: device) } label: {
                    Label(state?.report == nil ? "Check flash (NAND) health" : "Check again", systemImage: "internaldrive")
                }
                .disabled(state?.running == true)
                .help("Reads the flash controller's own lifetime statistics over USB: bad blocks, read/program/erase failures and wear. Doesn't change anything.")
                if state?.running == true { ProgressView().controlSize(.small) }
            }
            if let error = state?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = state?.report {
                Label(report.headline, systemImage: icon(report.verdict))
                    .foregroundStyle(color(report.verdict)).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(report.rows) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary)
                            Text(row.value)
                                .foregroundStyle(row.flag.map { color($0) } ?? Color.primary)
                                .textSelection(.enabled)
                                .help(row.note ?? "")
                        }
                    }
                }
                .font(.callout)
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainText, forType: .string)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.top, 4)
    }

    private func icon(_ v: NANDHealthReport.Verdict) -> String {
        switch v {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "xmark.octagon.fill"
        }
    }

    private func color(_ v: NANDHealthReport.Verdict) -> Color {
        switch v {
        case .good: return .green
        case .warning: return .orange
        case .failing: return .red
        }
    }
}
