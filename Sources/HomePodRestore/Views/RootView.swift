import SwiftUI
import HomePodRestoreCore

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case restore, firmware, health, diags, nicotine, setup, help
    var id: String { rawValue }

    var title: String {
        switch self {
        case .restore: return "Restore"
        case .firmware: return "Firmware"
        case .health: return "Health Check"
        case .diags: return "DIAGS Shell"
        case .nicotine: return "Nicotine (Linux)"
        case .setup: return "Setup"
        case .help: return "Help & Credits"
        }
    }

    var icon: String {
        switch self {
        case .restore: return "arrow.counterclockwise.circle"
        case .firmware: return "shippingbox"
        case .health: return "stethoscope"
        case .diags: return "terminal"
        case .nicotine: return "homepod.fill"
        case .setup: return "wrench.and.screwdriver"
        case .help: return "questionmark.circle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: AppSection? = .restore

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(AppSection.allCases) { s in
                    NavigationLink(value: s) {
                        Label(s.title, systemImage: s.icon)
                            .badge(badge(for: s))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            VStack(spacing: 0) {
                if let a = model.manifest.announcement, !a.isEmpty {
                    Banner(icon: "megaphone.fill", text: a, tint: .blue)
                }
                switch section ?? .restore {
                case .restore: RestoreView(goTo: { section = $0 })
                case .firmware: FirmwareView()
                case .health: HealthView()
                case .diags: DiagsShellView()
                case .nicotine: NicotineView()
                case .setup: SetupView()
                case .help: HelpView()
                }
            }
            .sheet(item: $model.syscfg) { SysCfgSheet(state: $0) }
            .sheet(item: $model.diag) { DiagnosticsSheet(state: $0) }
            // "Boot Nicotine" on a device card shows its progress on the Nicotine page.
            .onChange(of: model.nicotineRevealToken) { _ in section = .nicotine }
        }
    }

    private func badge(for s: AppSection) -> Int {
        switch s {
        case .restore: return model.runningJobCount
        case .setup: return model.restoreToolsReady || model.tools.isEmpty ? 0 : 1
        default: return 0
        }
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Link(destination: model.discordURL) {
                Label("Get help on Discord", systemImage: "bubble.left.and.bubble.right.fill")
            }
            Link(destination: model.donateURL) {
                Label("Donate (PayPal)", systemImage: "heart.fill")
            }
            .foregroundStyle(.pink)
            Text("Made by Nic's Fix • v\(model.appVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

/// A coloured strip with an icon and message, optionally with an action.
struct Banner: View {
    let icon: String
    let text: String
    var tint: Color = .orange
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12))
    }
}

/// Page header used by every section.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

/// Rounded "card" container.
struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder((tint ?? Color.secondary).opacity(tint == nil ? 0.15 : 0.6), lineWidth: tint == nil ? 1 : 2))
    }
}

/// Numbered instruction row.
struct StepRow: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 30, height: 30)
                Text("\(number)").font(.callout.weight(.bold)).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
