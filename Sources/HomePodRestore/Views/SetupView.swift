import SwiftUI
import HomePodRestoreCore

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var builderExpanded = false

    private var restoreTools: [ToolStatus] { model.tools.filter { $0.tool.isRequiredForRestore || $0.tool == .irecovery } }
    private var builderTools: [ToolStatus] { model.tools.filter { $0.tool.isRequiredForBuild } }
    private var bundled: Bool { model.tools.contains { $0.isBundled } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Setup", subtitle: "The free tools that talk to your HomePod. You only need to do this once.") {
                    Button {
                        Task { await model.refreshTools() }
                    } label: {
                        if model.checkingTools { ProgressView().controlSize(.small) } else { Label("Check again", systemImage: "arrow.clockwise") }
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    toolList(title: "Restore tools", tools: restoreTools)
                    if !model.gasterSupportsECID && model.tools.contains(where: { $0.tool == .gaster && $0.isInstalled }) {
                        Banner(icon: "square.stack.3d.up.fill",
                               text: "Want to restore several HomePods at once? Run the installer — it adds a version of gaster that can pick one HomePod out of many.",
                               tint: .blue, actionTitle: "Install…") { model.openInstaller(builder: false) }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    DisclosureGroup(isExpanded: $builderExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Only needed if you want to build your own firmware. Most people don't.")
                                .font(.callout).foregroundStyle(.secondary)
                            toolList(title: nil, tools: builderTools)
                            Button { model.openInstaller(builder: true) } label: {
                                Label("Install restore + builder tools…", systemImage: "terminal")
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Firmware builder tools (advanced)").font(.headline)
                    }
                    Card {
                        Toggle(isOn: $model.showAdvanced) {
                            Text("Experimental: SysCfg read / restore").font(.headline)
                        }
                        Text("Adds “Read SysCfg” and “Restore SysCfg from dump…” to each HomePod's Check-health menu. For NAND-swap repairs — it reads and writes the unit's own serial and MAC addresses. Needs the builder tools and a one-time SSH-ramdisk build.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    whereThingsAre
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder private var statusCard: some View {
        Card(tint: model.restoreToolsReady ? .green : .orange) {
            if model.tools.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Checking your Mac…") }
            } else if model.restoreToolsReady {
                Label(bundled ? "Ready — the tools are built into this app." : "Ready — everything needed to restore is installed.",
                      systemImage: "checkmark.seal.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(.green)
                if model.tools.contains(where: { $0.warning != nil && $0.tool.isRequiredForRestore }) {
                    Text("Some tools have warnings below. Running the installer again usually fixes them.")
                        .font(.callout).foregroundStyle(.secondary)
                    installButton
                }
            } else {
                Label("One-time setup needed", systemImage: "wrench.and.screwdriver.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(.orange)
                Text("Click Install. A Terminal window opens and installs everything for you (the same steps as the guide). It takes 5–15 minutes; type your Mac password if asked — nothing shows while you type, that's normal. When it says “All set”, come back and click Check again.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                installButton
            }
        }
    }

    private var installButton: some View {
        HStack {
            Button { model.openInstaller(builder: false) } label: {
                Label("Install / Repair tools", systemImage: "terminal")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Link("What does this install?", destination: Links.guide).font(.callout)
        }
    }

    private func toolList(title: String?, tools: [ToolStatus]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            Card {
                ForEach(tools) { t in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(t)).foregroundStyle(color(t)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.tool.rawValue).font(.body.monospaced().weight(.medium))
                                if let v = t.version { Text(v).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Text(t.tool.purpose).font(.caption).foregroundStyle(.secondary)
                            if let w = t.warning { Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                            if let p = t.path {
                                Text(t.isBundled ? "Built into the app" : p.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            } else {
                                Text("Not installed (Homebrew: \(t.tool.brewFormula))").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    if t.id != tools.last?.id { Divider() }
                }
            }
        }
    }

    private func icon(_ t: ToolStatus) -> String {
        if !t.isInstalled { return t.tool.isRequiredForRestore ? "xmark.circle.fill" : "circle.dashed" }
        return t.warning == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func color(_ t: ToolStatus) -> Color {
        if !t.isInstalled { return t.tool.isRequiredForRestore ? .red : .secondary }
        return t.warning == nil ? .green : .orange
    }

    private var whereThingsAre: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where things are").font(.headline)
            HStack(spacing: 10) {
                Button("Logs") { NSWorkspace.shared.open(AppPaths.logs) }
                Button("Firmware") { NSWorkspace.shared.open(AppPaths.firmware) }
                Button("Restore cache") { NSWorkspace.shared.open(AppPaths.restoreCache) }
                Button("Build folder") {
                    try? FileManager.default.createDirectory(at: IPSWBuilder.workDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(IPSWBuilder.workDirectory)
                }
            }
            .controlSize(.small)
            Text("The restore cache holds the unpacked firmware (~3.3 GB) so restores start quickly. It's safe to delete; it's recreated when needed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
