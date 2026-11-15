import SwiftUI
import UniformTypeIdentifiers
import HomePodRestoreCore

struct FirmwareView: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false
    @State private var importError: String?
    @State private var showBuilder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Firmware", subtitle: "The HomePod software that gets installed. Most people only need the recommended download.")
                VStack(alignment: .leading, spacing: 18) {
                    recommended
                    library
                    buildYourOwn
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .zip, .zip]) { result in
            if case .success(let url) = result {
                Task { importError = await model.importFirmware(url) }
            }
        }
        .sheet(isPresented: $showBuilder) { BuildFirmwareView() }
    }

    // MARK: Recommended (prebuilt from nicsfix.com)

    private var recommended: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ready-made firmware").font(.title3.weight(.semibold))
            ForEach(model.manifest.firmwares) { entry in
                Card(tint: entry.recommended == true ? .accentColor : nil) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("HomePod \(entry.version)").font(.headline)
                                Text(entry.build).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if entry.recommended == true {
                                    Text("Recommended").font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                }
                                SignedBadge(signed: model.isSigned(entry.build))
                            }
                            if let note = entry.note { Text(note).font(.callout).foregroundStyle(.secondary) }
                            if let size = entry.size { Text(ByteFormat.string(size) + " download").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        downloadControl(entry)
                    }
                    if let state = model.downloads[entry.url.absoluteString] {
                        if let p = state.progress, state.error == nil {
                            ProgressView(value: p.fraction ?? 0)
                            Text(ByteFormat.progress(p)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let e = state.error {
                            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                            Text("Downloads resume where they left off — just click Download again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Only versions Apple still signs can be installed. Restoring 26.0.1 has caused boot loops — restore 18.3, then let the HomePod update itself from the Home app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func downloadControl(_ entry: PrebuiltManifest.Entry) -> some View {
        if let item = model.localItem(for: entry) {
            if model.selectedFirmwareID == item.id {
                Label("Downloaded • In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Use this") { model.selectedFirmwareID = item.id }
            }
        } else if model.isDownloading(entry) {
            Button("Cancel") { model.cancelDownload(entry) }
        } else {
            Button {
                model.download(entry)
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("On this Mac").font(.title3.weight(.semibold))
                Spacer()
                Button { importing = true } label: { Label("Add .ipsw file…", systemImage: "plus") }
                Button { NSWorkspace.shared.open(AppPaths.firmware) } label: { Label("Open folder", systemImage: "folder") }
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if model.library.isEmpty {
                Text("Nothing yet. Download the recommended firmware above, or add an .ipsw you already have.")
                    .foregroundStyle(.secondary)
            } else {
                Card {
                    ForEach(model.library) { item in
                        LibraryRow(item: item)
                        if item.id != model.library.last?.id { Divider() }
                    }
                }
            }
        }
    }

    // MARK: Build your own

    private var buildYourOwn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Build your own (advanced)").font(.title3.weight(.semibold))
            Card {
                Text("Make an .ipsw from Apple's own HomePod software using tihmstar's makeipsw.sh. The app downloads the HomePod update from Apple, just the parts it needs from the matching Apple TV HD firmware (about 100 MB instead of 5 GB), and the firmware keys — then builds it for you.")
                    .font(.callout)
                Text("Takes 20–40 minutes and about 25 GB of free space. Needs the builder tools from Setup.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button {
                        showBuilder = true
                    } label: { Label("Build firmware…", systemImage: "hammer") }
                    if let b = model.build {
                        if b.running {
                            ProgressView().controlSize(.small)
                            Text("Building \(b.release.version)…").font(.callout)
                        } else if b.error != nil {
                            Label("Last build failed", systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
                        } else if b.finished != nil {
                            Label("Built \(b.release.version)", systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout)
                        }
                    }
                }
            }
        }
    }
}

struct LibraryRow: View {
    let item: FirmwareItem
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.selectedFirmwareID == item.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(model.selectedFirmwareID == item.id ? Color.accentColor : .secondary)
                .font(.title3)
                .onTapGesture { model.selectedFirmwareID = item.id }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.displayName).font(.headline)
                    SignedBadge(signed: model.isSigned(item.info.buildVersion))
                }
                HStack(spacing: 6) {
                    Text(originText)
                    Text("•")
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    if let p = model.preparing[item.id] {
                        Text("•"); Text("Unpacking \(Int(p * 100))%")
                    } else if FilesystemCache.isReady(for: item) {
                        Text("•"); Text("Ready")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !item.info.isCustomHomePodBuild {
                    Text("This doesn't look like a makeipsw.sh build — a stock Apple file won't restore over USB.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove")
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedFirmwareID = item.id }
        .confirmationDialog("Remove \(item.displayName)?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { model.remove(item) }
        } message: {
            Text(item.path.hasPrefix(AppPaths.firmware.path) ? "The file will be deleted to free up space." : "The file stays where it is; it's just removed from this list.")
        }
    }

    private var originText: String {
        switch item.origin {
        case .prebuilt: return "Downloaded"
        case .built: return "Built on this Mac"
        case .imported: return "Added by you"
        }
    }
}

/// Pick a HomePod version and build an IPSW for it.
struct BuildFirmwareView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var selected: BuildableRelease.ID?
    @State private var showUnsigned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Build firmware").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let b = model.build {
                buildProgress(b)
            } else {
                picker
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .task { if model.releases.isEmpty { await model.loadReleases() } }
    }

    private var visibleReleases: [BuildableRelease] {
        model.releases.filter { showUnsigned || $0.isSigned }
    }

    @ViewBuilder private var picker: some View {
        let missing = Tool.allCases.filter { t in t.isRequiredForBuild && model.tools.first { $0.tool == t }?.isInstalled != true }
        if !missing.isEmpty {
            Banner(icon: "wrench.and.screwdriver.fill",
                   text: "Install the builder tools first: \(missing.map(\.rawValue).joined(separator: ", ")).",
                   tint: .orange, actionTitle: "Install…") { model.openInstaller(builder: true) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        Text("Choose a HomePod software version. Only versions Apple still signs will restore.")
            .foregroundStyle(.secondary)
        Toggle("Show versions Apple no longer signs", isOn: $showUnsigned)
        if model.loadingReleases {
            ProgressView("Loading versions from ipsw.me…")
        } else if let e = model.releasesError {
            Label(e, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
            Button("Try again") { Task { await model.loadReleases() } }
        } else {
            List(visibleReleases, selection: $selected) { r in
                HStack {
                    Text("HomePod \(r.version)").font(.headline)
                    Text(r.build).font(.caption.monospaced()).foregroundStyle(.secondary)
                    SignedBadge(signed: r.isSigned)
                    Spacer()
                    if r.donor == nil {
                        Text("No Apple TV match").font(.caption).foregroundStyle(.orange)
                    }
                    if let size = r.ota.filesize { Text(ByteFormat.string(size)).font(.caption).foregroundStyle(.secondary) }
                }
                .tag(r.id)
            }
            .frame(minHeight: 260)
        }
        HStack {
            Text("Builds land in the Firmware list when done.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Build") {
                if let r = model.releases.first(where: { $0.id == selected }) { model.startBuild(r) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected == nil || model.releases.first(where: { $0.id == selected })?.donor == nil || !missing.isEmpty)
        }
    }

    @ViewBuilder private func buildProgress(_ b: AppModel.BuildState) -> some View {
        Text("HomePod \(b.release.version) (\(b.release.build))").font(.headline)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(IPSWBuilder.Stage.allCases.filter { $0 != .done }, id: \.self) { stage in
                HStack {
                    if b.finished != nil || stage < b.update.stage {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if stage == b.update.stage && b.error == nil {
                        ProgressView().controlSize(.mini).frame(width: 14)
                    } else if stage == b.update.stage {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                    }
                    Text(stage.title)
                }
            }
        }
        if b.running {
            if let p = b.update.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
            Text(b.update.detail).font(.caption).foregroundStyle(.secondary)
            if b.update.stage == .building {
                Text("macOS will ask for your password — makeipsw.sh needs it to create disk images.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let e = b.error {
            ScrollView { Text(e).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 160)
                .padding(8).background(Color.red.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
        if b.finished != nil {
            Label("Done! It's selected and ready to restore.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        }
        if !b.log.isEmpty {
            DisclosureGroup("Build log") {
                ScrollView {
                    Text(b.log.suffix(300).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
        }
        Spacer()
        HStack {
            Spacer()
            if b.running {
                Button("Cancel build", role: .destructive) { model.cancelBuild() }
            } else {
                Button("Build another") { model.clearBuild() }
            }
        }
    }
}
