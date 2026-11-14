import SwiftUI

#if !CHECKS
/// Custom entry point: when ssh runs FileHub as SSH_ASKPASS, the process only answers the
/// password prompt and exits before any UI is created.
@main
enum Launcher {
    static func main() {
        AskpassHelper.runIfRequested()
        Darcula.prepare()
        // Writing to a pipe whose reader has exited must not terminate the app.
        signal(SIGPIPE, SIG_IGN)
        FileHubApp.main()
    }
}
#endif

struct FileHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("FileHub", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .darculaWindow()
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Verbindung") {
                Button("Verbinden") { model.connect() }
                    .keyboardShortcut("k")
                    .disabled(model.activeServer == nil || model.isBusy || model.isOnline)
                Button("Trennen") { model.disconnect() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!model.isOnline && model.connection != .connecting)
                Divider()
                Button("Neue Verbindung …") { model.newServer() }
                    .keyboardShortcut("n")
                    .disabled(model.job != nil)
                Button("Verbindung bearbeiten …") { model.editServer() }
                    .keyboardShortcut("e")
                    .disabled(model.activeServer == nil || model.job != nil)
                Button("Verbindung löschen …") { model.deleteServer() }
                    .disabled(model.activeServer == nil || model.job != nil)
                Divider()
                Button("Verbindungen exportieren …") { model.exportSetup() }
                    .disabled(model.servers.isEmpty || model.job != nil)
                Button("Verbindungen importieren …") { model.importSetup() }
                    .disabled(model.job != nil)
            }
            CommandMenu("Dateien") {
                FileCommands(model: model)
            }
        }
    }
}

/// The Files menu. Folder, rename and delete act on the column last clicked (Mac or server), so
/// ⌘⌫ in the Mac column moves to the Trash instead of deleting on the server.
struct FileCommands: View {
    let model: AppModel

    var body: some View {
        let pane = model.actionPane
        let local = pane == .local
        let selected = local ? model.localSelection.count : model.remoteSelection.count
        let where_ = local ? "auf dem Mac" : "auf dem Server"
        Button("Aktualisieren") { model.refreshBoth() }
            .keyboardShortcut("r")
        Divider()
        Button("Auswahl hochladen") { model.uploadSelection() }
            .keyboardShortcut("u")
            .disabled(!model.canTransfer || model.localSelection.isEmpty)
        Button("Auswahl herunterladen") { model.downloadSelection() }
            .keyboardShortcut("d")
            .disabled(!model.canTransfer || model.remoteSelection.isEmpty)
        Divider()
        Button("Öffnen") { if !Self.textKey({ $0.moveToEndOfDocument(nil) }) { model.openSelection(pane) } }
            .keyboardShortcut(.downArrow)
            .disabled(selected != 1 || (!local && !model.canTransfer))
        Button("Übergeordneter Ordner") { if !Self.textKey({ $0.moveToBeginningOfDocument(nil) }) { model.goUp(pane) } }
            .keyboardShortcut(.upArrow)
            .disabled(local ? model.localURL.path == "/" : !model.canTransfer || model.remotePath == "/")
        Divider()
        Button("Neuer Ordner \(where_) …") { local ? model.newLocalFolder() : model.newRemoteFolder() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!local && !model.canTransfer)
        Button("Umbenennen \(where_) …") { local ? model.renameLocal() : model.renameRemote() }
            .disabled(selected != 1 || (local ? model.job != nil : !model.canTransfer))
        Button("Rechte ändern …") { model.changeRemoteMode() }
            .disabled(local || !model.canTransfer || selected == 0)
        Button("Pfad kopieren") { model.copyPaths(pane) }
            .keyboardShortcut("c", modifiers: [.command, .option])
        Button(local ? "In den Papierkorb legen" : "Auf dem Server löschen …") {
            if !Self.textKey({ $0.deleteToBeginningOfLine(nil) }) { local ? model.trashLocal() : model.deleteRemote() }
        }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(selected == 0 || (local ? model.job != nil : !model.canTransfer))
        Divider()
        Button("Protokolldatei zeigen") { NSWorkspace.shared.activateFileViewerSelecting([LogFile.url]) }
    }

    /// Menu shortcuts come before text editing: while a text field (path, sheet, dialog) has the
    /// focus, ⌘⌫ and ⌘↑/⌘↓ edit the text instead of deleting files or changing folders.
    private static func textKey(_ edit: (NSTextView) -> Void) -> Bool {
        guard NSApp.currentEvent?.type == .keyDown, let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        edit(text)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Darcula.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without an Xcode project the app would not start as a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if SNAPSHOT
        Snapshot.start()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated({ AppModel.shared.job != nil }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Eine Übertragung läuft noch"
        alert.informativeText = "Beim Beenden bricht sie ab; halb übertragene Dateien bleiben unvollständig. Trotzdem beenden?"
        alert.addButton(withTitle: "Weiterlaufen lassen")
        alert.addButton(withTitle: "Beenden")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}
