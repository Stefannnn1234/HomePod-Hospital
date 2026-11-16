import Foundation
import AppKit
import HomePodRestoreCore

// MARK: - DIAGS shell over serial (UART)
//
// The factory DIAGS shell is reached through a USB-to-serial adapter, not over
// the HomePod's USB port — so none of this depends on the device list. A pod
// can be connected, absent, or mid-boot; the serial side works the same.
//
// Same shape as the other AppModel extensions: the published state lives in
// AppModel.swift (`diagsSession`, `serialPortPath`, `diagsLog`, …), the work
// runs off the main thread, and every state change hops back to the main actor.
//
// Threading: `SerialPort` / `DiagsSerialSession` block, so every call into
// them goes through ONE serial dispatch queue (`diagsSerialQueue`). That keeps
// the UI responsive and guarantees a command's reply can't be interleaved with
// the idle reader that shows unsolicited output between commands.

/// One block in the DIAGS output area: a command that was run, a status note,
/// or text the pod printed on its own.
struct DiagsLogEntry: Identifiable, Equatable {
    enum Kind { case command, note, console }

    let id = UUID()
    let date: Date
    var kind: Kind
    /// What ran — the button's label ("System Info") or "Console".
    var label: String
    /// The command line, for `.command` entries.
    var command: String?
    var text: String
    var isError: Bool

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var timestamp: String { Self.clock.string(from: date) }

    /// `[12:03:44] System Info — sysinfo`
    var header: String {
        var s = "[\(timestamp)] \(label)"
        if let command, !command.isEmpty { s += " — \(command)" }
        return s
    }
}

/// Why a model reconfiguration couldn't start, or couldn't finish.
enum DiagsModelReconfigureError: LocalizedError {
    /// Not connected, or another command is running.
    case notReady
    /// The serial connection went away part-way through.
    case disconnected

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The DIAGS shell isn't ready — connect, and wait for the command that is running to finish."
        case .disconnected:
            return "The serial connection was lost part-way through. Reconnect and read Mod#, CLCG and CLHS (syscfg print <key>) to see what was written, then run the reconfiguration again."
        }
    }
}

private let diagsSerialQueue = DispatchQueue(label: "com.nicsfix.homepodrestore.diags-serial", qos: .userInitiated)

/// Runs blocking serial work on the serial queue and resumes with its result.
private func diagsSerialWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        diagsSerialQueue.async {
            continuation.resume(with: Result(catching: work))
        }
    }
}

@MainActor
extension AppModel {

    var diagsConnected: Bool { diagsSession != nil }

    /// Buttons are live only when connected and nothing else is running.
    var diagsReady: Bool { diagsSession != nil && diagsBusy == nil }

    // MARK: Ports

    /// Re-scans `/dev/cu.*`. Keeps the current selection while it still exists
    /// (or is in use); otherwise picks the first likely USB-to-serial adapter.
    func refreshSerialPorts() {
        let ports = SerialPort.availablePorts()
        if ports != serialPorts { serialPorts = ports }
        if let selected = serialPortPath, ports.contains(selected) || diagsSession != nil { return }
        let remembered = UserDefaults.standard.string(forKey: "diagsSerialPort")
        let pick = ports.first { $0 == remembered } ?? ports.first(where: SerialPort.isLikelyUSBSerial)
        if serialPortPath != pick { serialPortPath = pick }
    }

    // MARK: Connect / disconnect

    func connectDiagsSerial(port: String) {
        guard diagsSession == nil, !diagsConnecting else { return }
        serialPortPath = port
        diagsConnecting = true
        diagsError = nil

        let serial = SerialPort(path: port)
        let session = DiagsSerialSession(port: serial)
        Task {
            do {
                try await diagsSerialWork { try serial.open() }
            } catch {
                diagsConnecting = false
                diagsError = error.localizedDescription
                return
            }
            diagsSession = session
            diagsConnecting = false
            UserDefaults.standard.set(port, forKey: "diagsSerialPort")
            appendDiagsNote("Connected", "\(port) — \(serial.baudRate) baud, 8N1, no flow control")

            // Is a DIAGS shell already there? Not finding one is not an error:
            // the tech may connect first and boot the pod afterwards.
            diagsBusy = "Looking for the DIAGS prompt"
            do {
                let prompt = try await diagsSerialWork { try session.waitForPrompt(timeout: 3) }
                guard diagsSession === session else { return }
                diagsECID = session.ecid
                appendDiagsNote("DIAGS shell ready", prompt)
            } catch let error as DiagsSerialError {
                guard diagsSession === session else { return }
                if case .noPrompt(let partial) = error, !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendDiagsConsole(partial)
                }
                appendDiagsNote("No DIAGS prompt yet",
                                "Nothing answered with a `:-)` prompt. Boot the pod into Factory DIAGS — its output will show up here as it arrives. If it is already booted, check the adapter's TX/RX wiring and the port.")
            } catch {
                guard diagsSession === session else { return }
                diagsFailed(error, label: "Connect", command: nil, session: session)
            }
            guard diagsSession === session else { return }
            diagsBusy = nil
            startDiagsIdleReader(session)
        }
    }

    func disconnectDiagsSerial() {
        guard let session = diagsSession else { return }
        closeDiagsSession(session)
        appendDiagsNote("Disconnected", session.port.path)
    }

    /// Drops the session and closes its port. `close()` can wait a moment for
    /// a read in flight, so it runs off the main thread.
    private func closeDiagsSession(_ session: DiagsSerialSession) {
        diagsIdleTask?.cancel()
        diagsIdleTask = nil
        if diagsSession === session {
            diagsSession = nil
            diagsBusy = nil
            diagsECID = nil
            diagsAudioReady = false
            // The next unit on this cable is a different HomePod.
            diagsCurrentModel = nil
            diagsCurrentRegion = nil
            diagsCurrentColorKeys = [:]
            diagsModelStatus = nil
            diagsModelFailed = false
        }
        DispatchQueue.global(qos: .utility).async { session.port.close() }
    }

    // MARK: Running commands

    /// Runs a quick-action button.
    func runDiagsAction(_ action: DiagsQuickAction) {
        let timeout = action.isSlow ? diagsSession?.longCommandTimeout : nil
        runDiagsCommands(action.commands, label: action.title, timeout: timeout) { [weak self] results in
            guard let self else { return }
            switch action.kind {
            case .sysCfgList:
                if let list = results.first {
                    self.diagsSysCfgEntries = DiagsSerialSession.parseSysCfgList(list.cleanOutput)
                    self.diagsSysCfgRaw = list.cleanOutput
                    self.noteDiagsModelIdentityFromList()
                }
            case .audioInit:
                // Each of these sends `ampcontroller --init` as its first line.
                if results.first?.succeeded == true { self.diagsAudioReady = true }
            default:
                break
            }
        }
    }

    /// Sends one line typed by the tech.
    func sendDiagsCommand(_ line: String) {
        runDiagsCommands([line], label: "Command", timeout: diagsSession?.longCommandTimeout)
    }

    /// `syscfg add <key> <value>`, then reads the key back so the result is
    /// visible. WRITES FLASH — only called from the SysCfg write form.
    func writeDiagsSysCfg(key: String, value: String) {
        let key = key.trimmingCharacters(in: .whitespaces)
        let value = value.trimmingCharacters(in: .whitespaces)
        guard DiagsSerialSession.isSysCfgKey(key) else {
            diagsSysCfgWriteStatus = DiagsSerialError.invalidKey(key).localizedDescription
            diagsSysCfgWriteFailed = true
            return
        }
        diagsSysCfgWriteStatus = nil
        diagsSysCfgWriteFailed = false
        runDiagsCommands(["syscfg add \(key) \(value)", "syscfg print \(key)"], label: "SysCfg Write",
                         timeout: diagsSession?.longCommandTimeout) { [weak self] results in
            guard let self, let add = results.first else { return }
            if !add.succeeded {
                self.diagsSysCfgWriteStatus = "DIAGS reported an error writing \(key) — see the output."
                self.diagsSysCfgWriteFailed = true
            } else if results.count > 1 {
                let readBack = DiagsSerialSession.parseSysCfgList(results[1].cleanOutput).first { $0.key == key }?.value
                    ?? results[1].cleanOutput
                self.diagsSysCfgWriteStatus = "Wrote \(key). Read back: \(readBack.isEmpty ? "(nothing)" : String(readBack.prefix(200)))"
                self.diagsSysCfgWriteFailed = results[1].hasError
            } else {
                self.diagsSysCfgWriteStatus = "Sent \(key), but the read-back didn't run — see the output."
                self.diagsSysCfgWriteFailed = true
            }
        }
    }

    /// `syscfg init` — creates an EMPTY SysCfg. WRITES FLASH. The form asks
    /// for confirmation before calling this.
    func initDiagsSysCfg() {
        diagsSysCfgWriteStatus = nil
        diagsSysCfgWriteFailed = false
        runDiagsCommands(["syscfg init"], label: "SysCfg Init", timeout: diagsSession?.longCommandTimeout) { [weak self] results in
            guard let self, let result = results.first else { return }
            self.diagsSysCfgWriteStatus = result.succeeded
                ? "SysCfg initialized (empty). Write the unit's keys back now."
                : "DIAGS reported an error initializing SysCfg — see the output."
            self.diagsSysCfgWriteFailed = !result.succeeded
            // Whatever the list showed before is no longer what's on the chip.
            self.diagsSysCfgEntries = []
            self.diagsSysCfgRaw = nil
            self.diagsCurrentModel = nil
            self.diagsCurrentRegion = nil
            self.diagsCurrentColorKeys = [:]
        }
    }

    // MARK: Model reconfiguration (colour swap)

    /// Takes the model number, region and colour keys from the last
    /// `syscfg list`, when it has them.
    func noteDiagsModelIdentityFromList() {
        if let model = diagsSysCfgEntries.first(where: { $0.key == DiagsSerialSession.modelKey })?.value, !model.isEmpty {
            diagsCurrentModel = model
        }
        if let region = diagsSysCfgEntries.first(where: { $0.key == "Regn" })?.value, !region.isEmpty {
            diagsCurrentRegion = region
        }
        for key in DiagsSerialSession.colorKeys {
            if let value = diagsSysCfgEntries.first(where: { $0.key == key })?.value, !value.isEmpty {
                diagsCurrentColorKeys[key] = value
            }
        }
    }

    /// `syscfg print` of `Mod#`, `Regn`, `CLCG` and `CLHS` — only reads. Fills
    /// `diagsCurrentModel` / `diagsCurrentRegion` / `diagsCurrentColorKeys`
    /// for the Reconfigure Model sheet; a key that errors (not set) leaves its
    /// value empty.
    func readDiagsModelIdentity() {
        let keys = [DiagsSerialSession.modelKey, "Regn"] + DiagsSerialSession.colorKeys
        runDiagsCommands(keys.map { "syscfg print \($0)" }, label: "Read Model",
                         timeout: diagsSession?.longCommandTimeout) { [weak self] results in
            guard let self else { return }
            for (key, result) in zip(keys, results) {
                let value = result.succeeded ? DiagsSerialSession.valueFromPrint(result.cleanOutput, key: key) : ""
                if key == DiagsSerialSession.modelKey {
                    self.diagsCurrentModel = value.isEmpty ? nil : value
                } else if key == "Regn" {
                    self.diagsCurrentRegion = value.isEmpty ? nil : value
                } else {
                    self.diagsCurrentColorKeys[key] = value.isEmpty ? nil : value
                }
            }
        }
    }

    /// Changes the unit's colour: the model number (`Mod#`) and the colour
    /// keys `CLCG` (Cover Glass Color) and `CLHS` (Housing Color). WRITES
    /// FLASH — only called from the Reconfigure Model sheet.
    ///
    /// Sends `DiagsSerialSession.modelReconfigureCommands(to:color:)` —
    /// delete + add for each key, then `syscfg print` of all three — logging
    /// each line like any other command, and returns the model number read
    /// back. `color` is the colour whose code goes into CLCG / CLHS; `nil`
    /// takes it from the model number. Throws when the model isn't valid
    /// (nothing is sent), when the shell is busy or goes away, or when a
    /// read-back isn't what was written.
    @discardableResult
    func reconfigureModel(to newModel: String, color: HomePodModelVariant? = nil) async throws -> String {
        // Validates first: a bad model must fail before `syscfg delete` runs.
        let commands = try DiagsSerialSession.modelReconfigureCommands(to: newModel, color: color)
        guard let session = diagsSession, diagsBusy == nil else { throw DiagsModelReconfigureError.notReady }
        let label = "Reconfigure Model"
        let timeout = session.longCommandTimeout
        diagsBusy = label
        diagsError = nil

        var results: [DiagsCommandResult] = []
        for command in commands {
            diagsBusy = "\(label) — \(command)"
            let result: DiagsCommandResult
            do {
                result = try await diagsSerialWork { try session.runCommand(command, timeout: timeout) }
            } catch {
                if diagsSession === session {
                    // Keys may already be deleted, so what is on the chip is unknown.
                    diagsCurrentModel = nil
                    diagsCurrentColorKeys = [:]
                    diagsFailed(error, label: label, command: command, session: session)
                    if diagsSession === session { diagsBusy = nil }
                }
                throw error
            }
            guard diagsSession === session else { throw DiagsModelReconfigureError.disconnected }
            results.append(result)
            appendDiagsLog(DiagsLogEntry(date: Date(), kind: .command, label: label, command: result.command,
                                         text: result.cleanOutput.isEmpty ? "(no output)" : result.cleanOutput,
                                         isError: !result.succeeded))
        }
        diagsBusy = nil

        do {
            let model = try DiagsSerialSession.verifiedModel(from: results, expected: newModel, color: color)
            diagsCurrentModel = model
            // Keep the SysCfg table in step. `diagsSysCfgRaw` is left alone on
            // purpose: it is the list as captured, i.e. the pre-change backup.
            var written = [DiagsSerialSession.modelKey: model]
            if let color = DiagsSerialSession.reconfigureColor(for: model, color: color) {
                for key in DiagsSerialSession.colorKeys {
                    written[key] = color.clcgArgs
                    diagsCurrentColorKeys[key] = color.clcgArgs
                }
            }
            for (key, value) in written {
                if let index = diagsSysCfgEntries.firstIndex(where: { $0.key == key }) {
                    diagsSysCfgEntries[index] = SysCfgEntry(key: key, value: value)
                }
            }
            return model
        } catch {
            // The keys were deleted first, so what is on the chip is unknown.
            diagsCurrentModel = nil
            diagsCurrentColorKeys = [:]
            throw error
        }
    }

    /// Button entry point for the sheet: runs `reconfigureModel(to:color:)`
    /// and turns its outcome into `diagsModelStatus`.
    func reconfigureDiagsModel(to newModel: String, color: HomePodModelVariant? = nil) {
        let previous = diagsCurrentModel
        let previousColorKeys = diagsCurrentColorKeys
        diagsModelStatus = nil
        diagsModelFailed = false
        Task {
            do {
                let model = try await reconfigureModel(to: newModel, color: color)
                if let written = DiagsSerialSession.reconfigureColor(for: model, color: color) {
                    diagsModelStatus = "This HomePod is now \(written.color): Mod# \(model), CLCG and CLHS \(written.colorCodeHex) — all three read back from the HomePod. Restore the firmware next; the iOS setup prompt will then show \(written.color)."
                } else {
                    diagsModelStatus = "Model number is now \(model). Read back from the HomePod. CLCG and CLHS were not changed — \(model) isn't a known colour."
                }
                diagsModelFailed = false
            } catch {
                var text = error.localizedDescription
                // A rejected model or a busy shell means nothing was sent, so
                // there is nothing to put back.
                var nothingSent = false
                if let diags = error as? DiagsSerialError, case .invalidModel = diags { nothingSent = true }
                if let own = error as? DiagsModelReconfigureError, case .notReady = own { nothingSent = true }
                if !nothingSent {
                    var before: [String] = []
                    if let previous, !previous.isEmpty { before.append("Mod# \(previous)") }
                    for key in DiagsSerialSession.colorKeys {
                        if let value = previousColorKeys[key], !value.isEmpty { before.append("\(key) \(value)") }
                    }
                    if !before.isEmpty { text += " Before this: " + before.joined(separator: "; ") + "." }
                }
                diagsModelStatus = text
                diagsModelFailed = true
            }
        }
    }

    /// Stops waiting for the command that is running. Nothing is sent to the
    /// pod; the port stays open.
    func cancelDiagsCommand() {
        diagsSession?.cancelCurrentCommand()
    }

    /// Sends `commands` one after another, logging each as it finishes, then
    /// calls `completion` with the results of the ones that ran. An `ERROR:`
    /// from one command doesn't stop the rest; a timeout, a cancel or a
    /// disconnect does.
    func runDiagsCommands(_ commands: [String], label: String, timeout: TimeInterval? = nil,
                          completion: (([DiagsCommandResult]) -> Void)? = nil) {
        guard let session = diagsSession, diagsBusy == nil, !commands.isEmpty else { return }
        diagsBusy = label
        diagsError = nil
        Task {
            var results: [DiagsCommandResult] = []
            for command in commands {
                diagsBusy = commands.count > 1 ? "\(label) — \(command)" : label
                do {
                    let result = try await diagsSerialWork { try session.runCommand(command, timeout: timeout) }
                    guard diagsSession === session else { return }
                    results.append(result)
                    if diagsECID == nil { diagsECID = session.ecid }
                    appendDiagsLog(DiagsLogEntry(date: Date(), kind: .command, label: label, command: result.command,
                                                 text: result.cleanOutput.isEmpty ? "(no output)" : result.cleanOutput,
                                                 isError: !result.succeeded))
                } catch {
                    guard diagsSession === session else { return }
                    diagsFailed(error, label: label, command: command, session: session)
                    break
                }
            }
            guard diagsSession === session else { return }
            diagsBusy = nil
            if !results.isEmpty { completion?(results) }
        }
    }

    /// Turns a thrown error into the right log entry — and, when the adapter
    /// is gone, tears the session down.
    private func diagsFailed(_ error: Error, label: String, command: String?, session: DiagsSerialSession) {
        func log(_ text: String) {
            appendDiagsLog(DiagsLogEntry(date: Date(), kind: .command, label: label, command: command, text: text, isError: true))
        }
        if let serial = error as? SerialPortError {
            switch serial {
            case .disconnected, .notOpen:
                log(serial.localizedDescription)
                diagsError = "The serial adapter was disconnected. Plug it back in and reconnect."
                closeDiagsSession(session)
            default:
                log(serial.localizedDescription)
            }
            return
        }
        if let diags = error as? DiagsSerialError {
            switch diags {
            case .commandTimedOut(_, let partial), .commandCancelled(_, let partial):
                log(partial.isEmpty ? diags.localizedDescription : partial + "\n\n" + diags.localizedDescription)
            case .invalidCommand, .invalidKey, .invalidValue, .invalidModel:
                diagsError = diags.localizedDescription
            case .noPrompt, .modelNotVerified, .colorNotVerified:
                log(diags.localizedDescription)
            }
            return
        }
        log(error.localizedDescription)
    }

    // MARK: Idle reader

    /// While nothing is running, shows whatever the pod prints on its own
    /// (iBoot and DIAGS boot output, async messages) and notices an unplugged
    /// adapter even when no command is in flight.
    private func startDiagsIdleReader(_ session: DiagsSerialSession) {
        diagsIdleTask?.cancel()
        diagsIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled, self.diagsSession === session else { return }
                guard self.diagsBusy == nil else { continue }
                do {
                    let text = try await diagsSerialWork { try session.readUnsolicited() }
                    guard !Task.isCancelled, self.diagsSession === session else { return }
                    if !text.isEmpty {
                        self.appendDiagsConsole(text)
                        if self.diagsECID == nil { self.diagsECID = session.ecid }
                    }
                } catch {
                    guard !Task.isCancelled, self.diagsSession === session else { return }
                    self.diagsFailed(error, label: "Console", command: nil, session: session)
                    return
                }
            }
        }
    }

    // MARK: Output log

    private static let diagsLogLimit = 400
    private static let diagsConsoleEntryLimit = 60_000

    func appendDiagsLog(_ entry: DiagsLogEntry) {
        diagsLog.append(entry)
        if diagsLog.count > Self.diagsLogLimit { diagsLog.removeFirst(diagsLog.count - Self.diagsLogLimit) }
        diagsLogRevision &+= 1
    }

    private func appendDiagsNote(_ label: String, _ text: String) {
        appendDiagsLog(DiagsLogEntry(date: Date(), kind: .note, label: label, command: nil, text: text, isError: false))
    }

    /// Unsolicited text. Consecutive chunks join one "Console" entry, so a
    /// boot log reads as one block instead of a hundred fragments.
    private func appendDiagsConsole(_ text: String) {
        if let last = diagsLog.indices.last, diagsLog[last].kind == .console,
           diagsLog[last].text.count < Self.diagsConsoleEntryLimit {
            diagsLog[last].text += text
            diagsLogRevision &+= 1
        } else {
            appendDiagsLog(DiagsLogEntry(date: Date(), kind: .console, label: "Console", command: nil, text: text, isError: false))
        }
    }

    func clearDiagsLog() {
        diagsLog.removeAll()
        diagsLogRevision &+= 1
    }

    /// The whole output area as plain text (Copy All / Save).
    func diagsTranscript() -> String {
        diagsLog.map { $0.header + "\n" + $0.text }.joined(separator: "\n\n")
    }

    /// Writes `text` to a file the user picks; shows an alert if that fails.
    func saveDiagsText(_ text: String, suggestedName: String, title: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.title = title
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
