import AppKit
import SwiftUI

@MainActor
final class DeskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    /// An agent left running would keep working with nobody to read its reply.
    func applicationWillTerminate(_: Notification) {
        AgentProcessGroups.shared.terminateAll()
    }
}

@main
struct DeskApp: App {
    @NSApplicationDelegateAdaptor(DeskAppDelegate.self) private var appDelegate
    @State private var model: DeskModel
    @State private var sidebar = SidebarControl()
    @Environment(\.openWindow) private var openWindow
    private let updater = Updater()

    init() {
        LegacyData.migrate()
        _model = State(initialValue: DeskModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, sidebar: sidebar)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    model.newThread()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About \(Brand.name)", action: AboutPanel.show)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.isAvailable)
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find in Thread…", action: model.beginFind)
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.selectedThread?.messages.isEmpty ?? true)
                Button("Find Next") { model.moveFind(1) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!model.isFinding)
                Button("Find Previous") { model.moveFind(-1) }
                    .keyboardShortcut("g", modifiers: [.shift, .command])
                    .disabled(!model.isFinding)
                if model.dictation.isAvailable {
                    Divider()
                    Button(model.dictation.isActive ? "Stop Voice Input" : "Start Voice Input", action: model.toggleDictation)
                        .keyboardShortcut("d", modifiers: [.shift, .command])
                        .disabled(model.selection == nil)
                }
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar", action: sidebar.toggle)
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button(model.showsFiles ? "Hide Files" : "Show Files") {
                    model.showsFiles.toggle()
                }
                .keyboardShortcut("i", modifiers: [.option, .command])
            }
            CommandGroup(replacing: .help) {
                Button("Welcome…") { openWindow(id: WelcomeView.windowID) }
                Button("How Roundtables Work") { openWindow(id: RoundtableHelpView.windowID) }
                Divider()
                Button("Open Thread Folder", action: model.openSelectedThreadFolder)
                    .disabled(model.selection == nil)
            }
            CommandMenu("Thread") {
                Button("Stop", action: model.stop)
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isRunning)
                Divider()
                Button("Previous Thread") { model.selectAdjacentThread(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                Button("Next Thread") { model.selectAdjacentThread(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                Divider()
                Button("Rename…", action: model.beginRenameOnSelection)
                    .keyboardShortcut("r", modifiers: [.shift, .command])
                    .disabled(model.selection == nil)
                Button(model.selectedThread?.archivedAt == nil ? "Archive" : "Unarchive", action: model.toggleArchiveOnSelection)
                    .keyboardShortcut("a", modifiers: [.shift, .command])
                    .disabled(model.selection == nil)
            }
        }

        WindowGroup("Preview", for: PreviewTarget.self) { $target in
            if let target {
                FilePreview(url: target.url, folder: target.folder)
                    .frame(minWidth: 480, minHeight: 360)
                    .navigationTitle(target.url.lastPathComponent)
            }
        }
        .defaultSize(width: 900, height: 900)

        Window("Welcome", id: WelcomeView.windowID) {
            WelcomeView(model: model)
        }
        .windowResizability(.contentSize)

        Window("How Roundtables Work", id: RoundtableHelpView.windowID) {
            RoundtableHelpView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
        }
    }
}
