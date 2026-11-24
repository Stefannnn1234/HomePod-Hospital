import SwiftUI
import HomePodRestoreCore

struct RestoreView: View {
    @EnvironmentObject var model: AppModel
    var goTo: (AppSection) -> Void
    @State private var showHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Restore", subtitle: "Plug in a HomePod and it shows up here automatically.") {
                    VStack(alignment: .trailing, spacing: 8) {
                        Toggle("Restore automatically when plugged in", isOn: $model.autoRestore)
                            .toggleStyle(.switch)
                            .help("Great for doing several HomePods: each one starts restoring as soon as it's connected.")
                        if model.readyDeviceCount > 1 {
                            Button {
                                model.restoreAllReady()
                            } label: {
                                Label("Restore all \(model.readyDeviceCount)", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    readinessBanners
                    FirmwareSummary(goTo: goTo)

                    if model.slots.isEmpty {
                        ConnectionGuide()
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                            ForEach(model.slots) { slot in
                                DeviceCard(slot: slot)
                            }
                        }
                        DisclosureGroup("How to connect another HomePod") {
                            ConnectionGuide(compact: true).padding(.top, 8)
                        }
                    }

                    if !model.history.isEmpty {
                        DisclosureGroup(isExpanded: $showHistory) {
                            VStack(spacing: 6) {
                                ForEach(model.history) { h in HistoryRow(state: h) }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("Earlier this session (\(model.history.count))").font(.headline)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder private var readinessBanners: some View {
        if !model.tools.isEmpty && !model.restoreToolsReady {
            Banner(icon: "wrench.and.screwdriver.fill",
                   text: "One-time setup needed: the restore tools aren't installed on this Mac yet.",
                   tint: .orange, actionTitle: "Go to Setup") { goTo(.setup) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        if let err = model.prepareError {
            Banner(icon: "exclamationmark.triangle.fill", text: "Couldn't unpack the firmware: \(err)", tint: .red)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Shows which firmware will be used, with a shortcut to change it.
struct FirmwareSummary: View {
    @EnvironmentObject var model: AppModel
    var goTo: (AppSection) -> Void

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill").font(.title).foregroundStyle(Color.accentColor)
                if let fw = model.selectedFirmware {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(fw.displayName).font(.headline)
                            SignedBadge(signed: model.isSigned(fw.info.buildVersion))
                        }
                        if let p = model.preparing[fw.id] {
                            ProgressView(value: p) { Text("Unpacking firmware (one-time)…").font(.caption) }
                                .frame(maxWidth: 320)
                        } else {
                            Text(FilesystemCache.isReady(for: fw) ? "Ready" : "Will be unpacked before the first restore (about a minute)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No firmware yet").font(.headline)
                        Text("Download the recommended HomePod software (about 3.4 GB).").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.selectedFirmware == nil, let rec = model.manifest.recommended {
                    if let d = model.downloads[rec.url.absoluteString], let p = d.progress {
                        VStack(alignment: .trailing) {
                            ProgressView(value: p.fraction ?? 0).frame(width: 200)
                            Text(ByteFormat.progress(p)).font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Download \(rec.version)") { model.download(rec) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Button(model.selectedFirmware == nil ? "More options" : "Change…") { goTo(.firmware) }
            }
        }
    }
}

struct SignedBadge: View {
    let signed: Bool?
    var body: some View {
        switch signed {
        case .some(true):
            Label("Signed by Apple", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.green)
                .help("Apple currently allows this version to be installed.")
        case .some(false):
            Label("Not signed", systemImage: "xmark.seal.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.red)
                .help("Apple no longer allows this version. Restores will fail with \"isn't eligible\".")
        case .none:
            EmptyView()
        }
    }
}

/// The physical setup steps, from the guide.
struct ConnectionGuide: View {
    var compact = false
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            if !compact {
                HStack {
                    Image(systemName: "hifispeaker.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Connect your HomePod").font(.title2.weight(.semibold))
                        Text("Waiting for a HomePod… it will appear here as soon as your Mac sees it.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                Divider()
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Do these in order, then click Restore (or Boot).").font(.callout.weight(.medium))
                    Spacer()
                    DFUGuideButton(action: "Restore",
                                   blocker: { model.blocker(for: $0, kind: .restore) },
                                   start: { model.startJob(.restore, on: $0) })
                        .controlSize(.small)
                }
                StepRow(number: 1, icon: "rectangle.portrait.bottomhalf.inset.filled",
                        title: "Open the base (first time only)",
                        detail: "Pry off the rubber base (between the base and the mesh) to reach the debug port, and clean off the adhesive so the adapter sits flat.")
                StepRow(number: 2, icon: "cable.connector",
                        title: "Attach the USB adapter",
                        detail: "Press the adapter onto the debug port. Don't solder to the port.")
                HStack(spacing: 6) {
                    Spacer().frame(width: 42)
                    Link("Need an adapter? Get one from the Nic's Fix shop →", destination: Links.shop).font(.callout)
                }
                StepRow(number: 3, icon: "laptopcomputer",
                        title: "Plug USB into your Mac",
                        detail: "Use a port directly on your Mac if you can (avoid unpowered hubs). If macOS asks to \"Allow accessory to connect\", click Allow. Leave the HomePod's power unplugged for now.")
                StepRow(number: 4, icon: "arrow.uturn.down.circle.fill",
                        title: "Turn it upside down",
                        detail: "Rest the HomePod on its top, with the adapter and USB cable still connected.")
                StepRow(number: 5, icon: "powerplug.fill",
                        title: "Plug in HomePod power — last",
                        detail: "Order matters: USB first, then power. The HomePod starts in DFU mode and shows up here within a few seconds.")
                HStack(spacing: 8) {
                    Spacer().frame(width: 42)
                    Label("Wait until it shows up here in DFU mode, then:", systemImage: "clock.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                StepRow(number: 6, icon: "arrow.uturn.up.circle.fill",
                        title: "Turn it right-side up — before you click Restore",
                        detail: "It stays in DFU mode. The HomePod reboots partway through a restore or boot; if it were still upside down then, it would drop back into DFU instead of carrying on. Keep the adapter, USB and power connected.")
            }
        }
    }
}

struct HistoryRow: View {
    @ObservedObject var state: JobState
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            OutcomeIcon(outcome: state.snapshot.outcome)
            Text(state.snapshot.kind.title).bold()
            Text("•").foregroundStyle(.secondary)
            Text(state.snapshot.status).lineLimit(1)
            Spacer()
            if let end = state.snapshot.finishedAt {
                Text(end, style: .time).foregroundStyle(.secondary).font(.caption)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([state.snapshot.logURL])
            } label: { Image(systemName: "doc.text.magnifyingglass") }
            .buttonStyle(.borderless)
            .help("Show log in Finder")
        }
        .padding(.vertical, 4)
    }
}

struct OutcomeIcon: View {
    let outcome: RestoreJob.Outcome
    var body: some View {
        switch outcome {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }
}
