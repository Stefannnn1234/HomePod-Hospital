import SwiftUI
import AppKit
import HomePodRestoreCore

@main
struct HomePodRestoreApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("HomePod Hospital") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    model.start()
                    delegate.model = model
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Restore Guide on GitHub") { NSWorkspace.shared.open(Links.guide) }
                Button("Get Help on Discord") { NSWorkspace.shared.open(model.discordURL) }
                Button("Known Errors Spreadsheet") { NSWorkspace.shared.open(Links.knownErrorsSheet) }
                Divider()
                Button("Open Logs Folder") { NSWorkspace.shared.open(AppPaths.logs) }
                Button("Open Firmware Folder") { NSWorkspace.shared.open(AppPaths.firmware) }
                Divider()
                Button("Donate to Nic's Fix…") { NSWorkspace.shared.open(model.donateURL) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting mid-restore can leave a HomePod half-written, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model?.runningJobCount ?? 0
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running == 1 ? "A HomePod is still restoring" : "\(running) HomePods are still restoring"
        alert.informativeText = "Quitting now will stop the restore. The HomePod won't be damaged, but you'll need to start over."
        alert.addButton(withTitle: "Keep Restoring")
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
