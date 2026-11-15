import SwiftUI
import AppKit
import HomePodRestoreCore

/// Button-driven front end to the factory DIAGS shell over a USB-to-serial
/// adapter. Works whether or not a pod is connected over USB — the serial
/// console is a separate cable.
struct DiagsShellView: View {
    @EnvironmentObject var model: AppModel
    @State private var showWriteSheet = false
    @State private var showModelSheet = false
    @State private var commandLine = ""
    /// A typed command that writes flash, waiting for the tech to confirm.
    @State private var pendingWriteCommand: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "DIAGS Shell",
                           subtitle: "Run Apple's factory diagnostics on a HomePod over a USB-to-serial (UART) adapter.")
                VStack(alignment: .leading, spacing: 16) {
                    connectionCard
                    if let error = model.diagsError {
                        Banner(icon: "exclamationmark.triangle.fill", text: error, tint: .red,
                               actionTitle: "Dismiss", action: { model.diagsError = nil })
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    quickActionsCard
                    if !model.diagsSysCfgEntries.isEmpty { sysCfgCard }
                    outputCard
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        // Keep the port list current while this screen is showing: adapters
        // come and go as they're plugged in.
        .task {
            while !Task.isCancelled {
                model.refreshSerialPorts()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .sheet(isPresented: $showWriteSheet) { DiagsSysCfgWriteSheet() }
        .sheet(isPresented: $showModelSheet) { DiagsModelReconfigureSheet() }
        .alert(pendingAlertTitle,
               isPresented: Binding(get: { pendingWriteCommand != nil }, set: { if !$0 { pendingWriteCommand = nil } })) {
            Button("Send", role: .destructive) {
                if let line = pendingWriteCommand { send(line) }
                pendingWriteCommand = nil
            }
            Button("Cancel", role: .cancel) { pendingWriteCommand = nil }
        } message: {
            Text(pendingAlertMessage)
        }
    }

    /// The line waiting for confirmation is one known to panic the pod (rather
    /// than one that writes flash).
    private var pendingCrashes: Bool {
        guard let line = pendingWriteCommand else { return false }
        return DiagsCommandReference.risk(ofLine: line) == .crashesDevice
    }

    private var pendingAlertTitle: String {
        pendingCrashes ? "Send a command that crashes the HomePod?" : "Send a command that writes to flash?"
    }

    private var pendingAlertMessage: String {
        let line = pendingWriteCommand ?? ""
        return pendingCrashes
            ? "\"\(line)\" is known to panic DIAGS. The HomePod will reboot into DFU and has to be booted into DIAGS again."
            : "\"\(line)\" changes data stored on the HomePod's flash. This can't be undone from here."
    }

    // MARK: Port selection

    private var connectionCard: some View {
        Card(tint: model.diagsConnected ? .green : nil) {
            HStack(spacing: 12) {
                Circle()
                    .fill(model.diagsConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                    .help(model.diagsConnected ? "Connected" : "Disconnected")
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()

                Picker("Serial port", selection: $model.serialPortPath) {
                    if model.serialPorts.isEmpty {
                        Text("No serial ports found").tag(String?.none)
                    } else if model.serialPortPath == nil {
                        Text("Choose a port").tag(String?.none)
                    }
                    ForEach(model.serialPorts, id: \.self) { path in
                        Text(portLabel(path)).tag(String?.some(path))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .disabled(model.diagsConnected || model.diagsConnecting)

                Button { model.refreshSerialPorts() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Look for serial ports again")
                    .disabled(model.diagsConnected || model.diagsConnecting)

                if model.diagsConnected {
                    Button("Disconnect") { model.disconnectDiagsSerial() }
                } else {
                    Button(model.diagsConnecting ? "Connecting…" : "Connect") {
                        if let path = model.serialPortPath { model.connectDiagsSerial(port: path) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.serialPortPath == nil || model.diagsConnecting)
                }
            }
            if !model.diagsConnected {
                Text("115200 baud, 8N1. Boot the pod with \"Boot Factory DIAGS\" (Restore → Check health, with advanced options on) or dev_boot.sh, then connect. The shell's prompt looks like \(DiagsCommandReference.prompt).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusTitle: String {
        if model.diagsConnecting { return "Connecting…" }
        guard model.diagsConnected else { return "Disconnected" }
        if let ecid = model.diagsECID { return "Connected — ECID \(ecid)" }
        return "Connected — waiting for the DIAGS prompt"
    }

    private var statusDetail: String {
        if let busy = model.diagsBusy { return "Running: \(busy)" }
        if model.diagsConnected, let path = model.serialPortPath { return path }
        return "Serial console (independent of the USB connection)"
    }

    private func portLabel(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("cu.") ? String(name.dropFirst(3)) : name
    }

    // MARK: Quick actions

    private var quickActionsCard: some View {
        Card {
            HStack {
                Text("Quick actions").font(.headline)
                Spacer()
                if let busy = model.diagsBusy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop waiting") { model.cancelDiagsCommand() }
                        .controlSize(.small)
                        .help("Give up on this command's reply. Nothing is sent to the HomePod.")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(DiagsQuickAction.categories) { category in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(category.title)
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(width: 160, alignment: .leading)
                            .help(category.blurb)
                        VStack(alignment: .leading, spacing: 6) {
                            // A few buttons per row, so a long group (Power,
                            // LED) wraps instead of running off the card.
                            ForEach(buttonRows(visibleActions(in: category).filter { !$0.isAudioPlayback }), id: \.first?.id) { row in
                                HStack(spacing: 8) {
                                    ForEach(row) { action in
                                        actionButton(action)
                                    }
                                }
                            }
                            // The two forms that write SysCfg get a row of
                            // their own, apart from the read-only buttons.
                            if category == .sysCfg {
                                HStack(spacing: 8) {
                                    Button { showWriteSheet = true } label: {
                                        Label("SysCfg Write…", systemImage: "square.and.pencil")
                                    }
                                    .tint(.orange)
                                    .help("Write SysCfg entries (serial number, MACs, calibration) — writes to flash.")
                                    .disabled(!model.diagsConnected)
                                    Button { showModelSheet = true } label: {
                                        Label("Reconfigure Model…", systemImage: "paintpalette")
                                    }
                                    .tint(.orange)
                                    .help("Change the model number (Mod#) for a colour swap — Space Gray ↔ White. Writes to flash.")
                                    .disabled(!model.diagsConnected)
                                }
                            }
                            // The buttons that make sound get a row of their own.
                            let playback = visibleActions(in: category).filter(\.isAudioPlayback)
                            if !playback.isEmpty {
                                HStack(spacing: 8) {
                                    ForEach(playback) { action in
                                        actionButton(action)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .disabled(!model.diagsReady)

            Divider()

            // A line typed by hand, for anything the buttons don't cover.
            HStack(spacing: 8) {
                TextField("Type a DIAGS command (for example: syscfg print SrNm)", text: $commandLine)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { submitCommandLine() }
                Button("Send") { submitCommandLine() }
                    .disabled(commandLine.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(!model.diagsReady)
            if let hint = commandHint {
                Label(hint.text, systemImage: hint.icon)
                    .font(.caption).foregroundStyle(hint.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Every quick action in the category. The Audio group includes the tone
    /// tests (Test Tone, Tone Sweep, Stop Audio); each tone test runs the amp
    /// init itself, so none of them waits on the Amp Init button.
    private func visibleActions(in category: DiagsCommand.Category) -> [DiagsQuickAction] {
        DiagsQuickAction.actions(in: category)
    }

    private static let buttonsPerRow = 4

    /// `actions` in rows of at most `buttonsPerRow`.
    private func buttonRows(_ actions: [DiagsQuickAction]) -> [[DiagsQuickAction]] {
        stride(from: 0, to: actions.count, by: Self.buttonsPerRow).map { start in
            Array(actions[start..<min(start + Self.buttonsPerRow, actions.count)])
        }
    }

    private func actionButton(_ action: DiagsQuickAction) -> some View {
        Button { model.runDiagsAction(action) } label: {
            Label(action.title, systemImage: action.symbol)
        }
        .help(action.help)
    }

    private struct CommandHint {
        let text: String
        let icon: String
        let tint: Color
    }

    /// What the reference says about the line being typed, and its risk.
    private var commandHint: CommandHint? {
        let line = commandLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        guard let command = DiagsCommandReference.command(forLine: line),
              let risk = DiagsCommandReference.risk(ofLine: line) else {
            return CommandHint(text: "Not in the command reference — effect unknown.", icon: "questionmark.circle", tint: .secondary)
        }
        switch risk {
        case .crashesDevice:
            return CommandHint(text: "\(risk.title). \(command.summary)", icon: "xmark.octagon.fill", tint: .red)
        case .writesFlash:
            return CommandHint(text: "\(risk.title). \(command.summary)", icon: "exclamationmark.triangle.fill", tint: .red)
        case .changesState, .unknown:
            return CommandHint(text: "\(risk.title). \(command.summary)", icon: "bolt.circle", tint: .orange)
        case .readOnly:
            return CommandHint(text: "\(risk.title). \(command.summary)", icon: "eye", tint: .secondary)
        }
    }

    private func submitCommandLine() {
        let line = commandLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, model.diagsReady else { return }
        let risk = DiagsCommandReference.risk(ofLine: line)
        if risk == .writesFlash || risk == .crashesDevice {
            pendingWriteCommand = line
        } else {
            send(line)
        }
    }

    private func send(_ line: String) {
        model.sendDiagsCommand(line)
        commandLine = ""
    }

    // MARK: SysCfg table

    private var sysCfgCard: some View {
        Card {
            HStack {
                Text("SysCfg — \(model.diagsSysCfgEntries.count) entries").font(.headline)
                Spacer()
                Button {
                    let serial = model.diagsSysCfgEntries.first { $0.key == "SrNm" }?.value
                    model.saveDiagsText(model.diagsSysCfgRaw ?? "", suggestedName: "syscfg-list-\(serial ?? model.diagsECID ?? "homepod").txt",
                                        title: "Save SysCfg list")
                } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .help("Save the full \"syscfg list\" output. Do this before a NAND swap — it is the only copy of the unit's identity and calibration.")
                Button { model.copyToClipboard(model.diagsSysCfgRaw ?? "") } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            Table(model.diagsSysCfgEntries) {
                TableColumn("Key") { (entry: SysCfgEntry) in
                    Text(entry.key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                .width(min: 50, ideal: 60, max: 80)
                TableColumn("Meaning") { (entry: SysCfgEntry) in
                    Text(entry.meaning ?? "—").foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 190, max: 260)
                TableColumn("Value") { (entry: SysCfgEntry) in
                    Text(Self.shortValue(entry))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .help(Self.valueTooltip(entry))
                }
            }
            .frame(height: min(CGFloat(model.diagsSysCfgEntries.count) * 28 + 34, 320))
            Text("Binary keys are shown as DIAGS prints them: 32-bit hex words.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func valueTooltip(_ entry: SysCfgEntry) -> String {
        entry.value.count > 600 ? "Long value — use Save… or Copy for the whole thing." : entry.value
    }

    /// Calibration blobs run to thousands of words; the table shows the start.
    private static func shortValue(_ entry: SysCfgEntry) -> String {
        guard entry.value.count > 120 else { return entry.value }
        let words = entry.words?.count
        return String(entry.value.prefix(100)) + " …" + (words.map { " (\($0) words)" } ?? "")
    }

    // MARK: Output

    private var outputCard: some View {
        Card {
            HStack {
                Text("Output").font(.headline)
                Spacer()
                Button {
                    model.saveDiagsText(model.diagsTranscript(), suggestedName: "diags-session-\(model.diagsECID ?? "homepod").txt",
                                        title: "Save DIAGS output")
                } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    .disabled(model.diagsLog.isEmpty)
                Button { model.copyToClipboard(model.diagsTranscript()) } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    .disabled(model.diagsLog.isEmpty)
                Button { model.clearDiagsLog() } label: { Label("Clear", systemImage: "trash") }
                    .disabled(model.diagsLog.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.diagsLog.isEmpty {
                            Text("Nothing yet. Connect, then press a button above — each command's output appears here with the time it ran.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.diagsLog) { entry in
                            DiagsLogRow(entry: entry).id(entry.id)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 360)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: model.diagsLogRevision) { _ in
                    if let last = model.diagsLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

/// One timestamped block in the output area.
private struct DiagsLogRow: View {
    let entry: DiagsLogEntry

    /// A single enormous Text is slow to lay out, so very long output is cut
    /// for display. Copy All / Save… always have the full text.
    private static let displayLimit = 20_000

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.header)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(entry.isError ? Color.red : (entry.kind == .command ? Color.accentColor : Color.secondary))
            Text(shown)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.text.count > Self.displayLimit {
                Text("… \(entry.text.count - Self.displayLimit) more characters not shown. Copy All and Save… include everything.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var shown: String {
        entry.text.count > Self.displayLimit ? String(entry.text.prefix(Self.displayLimit)) : entry.text
    }
}

/// Form for writing SysCfg entries over the DIAGS shell: `syscfg add` for one
/// key, and `syscfg init` (behind a confirmation) for a brand-new NAND.
struct DiagsSysCfgWriteSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var key = ""
    @State private var value = ""
    @State private var confirmInit = false

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespaces) }
    private var trimmedValue: String { value.trimmingCharacters(in: .whitespaces) }
    private var keyValid: Bool { DiagsSerialSession.isSysCfgKey(trimmedKey) }
    private var canWrite: Bool { model.diagsReady && keyValid && !trimmedValue.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Write SysCfg").font(.title2.weight(.semibold))
                    Text(model.diagsECID.map { "HomePod • ECID \($0)" } ?? "Factory DIAGS shell")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Banner(icon: "exclamationmark.triangle.fill",
                   text: "These commands write to the HomePod's flash and can't be undone from here. Save the unit's \"syscfg list\" output first. \"Initialize SysCfg\" erases every entry — serial number, MAC addresses and factory calibration.",
                   tint: .red)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if !model.diagsConnected {
                Label("Not connected to a DIAGS shell.", systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Key").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    TextField("SrNm", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 90)
                        .onChange(of: key) { new in
                            // Keys are exactly four characters.
                            if new.count > 4 { key = String(new.prefix(4)) }
                        }
                    Menu("Common keys") {
                        ForEach(SysCfgEntry.knownKeys.keys.sorted(), id: \.self) { known in
                            Button(Self.keyMenuTitle(known)) { key = known }
                        }
                    }
                    .fixedSize()
                    if let meaning = SysCfgEntry.knownKeys[trimmedKey] {
                        Text(meaning).font(.caption).foregroundStyle(.secondary)
                    } else if !trimmedKey.isEmpty && !keyValid {
                        Text("Four characters, like SrNm or MLB#").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Value").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    TextField("CC4VKKTQHQK8", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { if canWrite { write() } }
                }
                Text("Enter the value exactly as `syscfg list` printed it — text for keys like SrNm, space-separated hex words (0xE37A81D0 0x00009476 …) for binary keys like WMac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let previous = lastListedValue {
                Text(verbatim: "Last listed value: " + previous)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if model.diagsBusy != nil { ProgressView().controlSize(.small) }
                if let status = model.diagsSysCfgWriteStatus {
                    Label(status, systemImage: model.diagsSysCfgWriteFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.diagsSysCfgWriteFailed ? .red : .green)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Button("Initialize SysCfg…", role: .destructive) { confirmInit = true }
                    .disabled(!model.diagsReady)
                    .help("Runs \"syscfg init\": creates an EMPTY SysCfg. Only for a brand-new NAND.")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Write Entry") { write() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canWrite)
                    .help(writeTooltip)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 440)
        .alert("Initialize SysCfg?", isPresented: $confirmInit) {
            Button("Erase and Initialize", role: .destructive) { model.initDiagsSysCfg() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs \"syscfg init\" and creates an EMPTY SysCfg. On a working unit it erases the serial number, MAC addresses and factory calibration, and they can only be put back from a saved \"syscfg list\". Only do this on a brand-new NAND.")
        }
    }

    private static func keyMenuTitle(_ key: String) -> String {
        key + " — " + (SysCfgEntry.knownKeys[key] ?? "")
    }

    private var writeTooltip: String {
        guard canWrite else { return "Enter a four-character key and a value." }
        return "Runs: syscfg add \(trimmedKey) \(String(trimmedValue.prefix(40))) — then reads the key back."
    }

    private var lastListedValue: String? {
        guard let previous = model.diagsSysCfgEntries.first(where: { $0.key == trimmedKey }) else { return nil }
        return previous.value.count > 160 ? String(previous.value.prefix(160)) + " …" : previous.value
    }

    private func write() {
        model.writeDiagsSysCfg(key: trimmedKey, value: trimmedValue)
    }
}

/// Form for changing the unit's model number (`Mod#`) over the DIAGS shell —
/// the colour swap: Space Gray (MQHW2) ↔ White (MQHV2). Writes flash.
struct DiagsModelReconfigureSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    /// `modelBase` of the colour picked.
    @State private var targetBase = HomePodModelVariant.white.modelBase
    /// What will be written. Filled from the picker; can be edited for a
    /// model that isn't one of the two listed.
    @State private var newModel = ""

    private var currentModel: String? { model.diagsCurrentModel }
    private var currentVariant: HomePodModelVariant? { currentModel.flatMap { HomePodModelVariant.variant(for: $0) } }
    private var target: HomePodModelVariant? { HomePodModelVariant.all.first { $0.modelBase == targetBase } }
    private var trimmedModel: String { newModel.trimmingCharacters(in: .whitespaces) }
    private var modelValid: Bool { (try? DiagsSerialSession.validatedModelNumber(trimmedModel)) != nil }
    private var unchanged: Bool { currentModel != nil && trimmedModel == currentModel }
    private var canReconfigure: Bool { model.diagsReady && modelValid && !unchanged }
    /// A `DClr` (device colour) key, if the last `syscfg list` had one.
    private var deviceColourKey: String? { model.diagsSysCfgEntries.first { $0.key == "DClr" }?.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "paintpalette").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reconfigure Model").font(.title2.weight(.semibold))
                    Text(model.diagsECID.map { "HomePod • ECID \($0)" } ?? "Factory DIAGS shell")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Banner(icon: "exclamationmark.triangle.fill",
                   text: "Changing the model number will make the system identify as a different color. LED calibration (LEDc) was factory-calibrated for the original mesh color and may look slightly off. This writes to the HomePod's flash — save the unit's \"syscfg list\" output first.",
                   tint: .orange)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if !model.diagsConnected {
                Label("Not connected to a DIAGS shell.", systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Current model").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Text(verbatim: currentModel ?? "Not read yet")
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    if let variant = currentVariant {
                        Label(variant.color, systemImage: variant.sfSymbol).font(.caption).foregroundStyle(.secondary)
                    } else if currentModel != nil {
                        Text("Not a known HomePod colour").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Button { model.readDiagsModelIdentity() } label: { Label("Read", systemImage: "arrow.clockwise") }
                        .controlSize(.small)
                        .disabled(!model.diagsReady)
                        .help("Runs: syscfg print Mod# and syscfg print Regn. Only reads.")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Region").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Text(verbatim: model.diagsCurrentRegion ?? "—")
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("Regn — not changed").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if let colour = deviceColourKey {
                    Text(verbatim: "This unit also has a DClr (device colour) key: \(String(colour.prefix(60))). It is not changed here — use SysCfg Write… if it needs to follow.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Text("Target colour").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Picker("Target colour", selection: $targetBase) {
                        ForEach(HomePodModelVariant.all) { variant in
                            Text("\(variant.color) (\(variant.modelBase))").tag(variant.modelBase)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("New model").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    TextField("MQHV2", text: $newModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                        .onSubmit { if canReconfigure { reconfigure() } }
                    if !trimmedModel.isEmpty && !modelValid {
                        Text("4 to 16 letters, digits, / or - (no spaces)").font(.caption).foregroundStyle(.orange)
                    } else if unchanged {
                        Text("Already this model").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text("Filled in from the colour above, keeping any region suffix the current model carries. Edit it for another variant.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if modelValid {
                Text(verbatim: "Will send:\n" + commandPreview)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if model.diagsBusy != nil { ProgressView().controlSize(.small) }
                if let status = model.diagsModelStatus {
                    Label(status, systemImage: model.diagsModelFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.diagsModelFailed ? .red : .green)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Reconfigure") { reconfigure() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReconfigure)
                    .help(canReconfigure ? "Deletes Mod#, writes \(trimmedModel), then reads it back." : "Connect, and enter a model number different from the current one.")
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 500)
        .onAppear {
            model.diagsModelStatus = nil
            model.diagsModelFailed = false
            // Prefer what the last `syscfg list` showed; otherwise ask the pod.
            if model.diagsCurrentModel == nil { model.noteDiagsModelIdentityFromList() }
            if model.diagsCurrentModel == nil, model.diagsReady { model.readDiagsModelIdentity() }
            pickOtherColour()
            fillNewModel()
        }
        .onChange(of: targetBase) { _ in fillNewModel() }
        .onChange(of: model.diagsCurrentModel) { _ in
            // The current model arrived (or changed after a write): only
            // refill while nothing has been written from this sheet.
            guard model.diagsModelStatus == nil else { return }
            pickOtherColour()
            fillNewModel()
        }
    }

    private var commandPreview: String {
        ((try? DiagsSerialSession.modelReconfigureCommands(to: trimmedModel)) ?? []).joined(separator: "\n")
    }

    /// Starts the picker on the colour the unit is NOT — the usual job.
    private func pickOtherColour() {
        guard let current = currentVariant,
              let other = HomePodModelVariant.all.first(where: { $0 != current }) else { return }
        targetBase = other.modelBase
    }

    private func fillNewModel() {
        guard let target else { return }
        newModel = HomePodModelVariant.remodel(currentModel ?? "", to: target)
    }

    private func reconfigure() {
        model.reconfigureDiagsModel(to: trimmedModel)
    }
}
