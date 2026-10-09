import AppKit
import SwiftUI
import Testing
@testable import Desk

/// Renders the window off-screen in states that need typing to reach.
/// Opt in with `DESK_SNAPSHOT_DIR=<out> DESK_SNAPSHOT_THREADS=<threads folder> swift test --disable-sandbox --filter Snapshot`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DESK_SNAPSHOT_DIR"] != nil))
struct SnapshotTests {
    private struct State {
        var name: String
        var draft = ""
        var dark = false
        var sends = false
        var files = false
        var file: String?
        var find: String?
    }

    @Test func renderStates() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(filePath: try #require(environment["DESK_SNAPSHOT_DIR"]), directoryHint: .isDirectory)
        let source = URL(filePath: try #require(environment["DESK_SNAPSHOT_THREADS"]), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let catalog = ModelCatalog()
        await catalog.refresh()

        let states = [
            State(name: "light"),
            State(name: "light-files", files: true),
            State(name: "dark-files", dark: true, files: true),
            State(name: "light-preview-md", files: true, file: "redirects.md"),
            State(name: "dark-preview-html", dark: true, files: true, file: "acme-survey-report.html"),
            State(name: "light-find", find: "the"),
            State(name: "dark-find", dark: true, find: "the"),
            State(name: "light-draft", draft: "do you have access to takibi"),
            State(name: "light-long", draft: "Compare the three pricing models above.\nWhich one survives a 200-person company on the Team plan?\nAnd what breaks first?"),
            State(name: "light-mention", draft: "@g"),
            State(name: "light-all", draft: "@all what would you cut from the Team plan?"),
            State(name: "light-streaming", draft: "@claude check the beta numbers in takibi", sends: true),
            State(name: "dark", draft: "@grok @claude compare these", dark: true),
            State(name: "dark-streaming", draft: "@claude check the beta numbers in takibi", dark: true, sends: true),
        ]
        for state in states {
            let threads = FileManager.default.temporaryDirectory.appending(path: "desk-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: source, to: threads)
            defer { try? FileManager.default.removeItem(at: threads) }
            let defaults = try #require(UserDefaults(suiteName: "desk-snapshot-\(UUID().uuidString)"))
            let model = DeskModel(
                store: ThreadStore(directory: threads),
                runner: StallingRunner(),
                trash: { _ in },
                defaults: defaults,
                catalog: catalog,
                supportDirectory: ThreadStore.supportDirectory,
                accountPicture: { AccountPicture.load() }
            )
            model.draft = state.draft
            if let find = state.find {
                model.showsArchived = true
                model.selection = model.threads.max { $0.messages.count < $1.messages.count }?.id
                model.beginFind()
                model.findQuery = find
                model.moveFind(-1)
            }
            if state.sends {
                model.send()
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
            NSApp.appearance = window.appearance
            window.contentView = NSHostingView(rootView: ContentView(model: model, startsWithFiles: state.files, startsWithFile: state.file))
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(900))
            let view = try #require(window.contentView)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appending(path: "\(state.name).png"))
            model.stop()
            window.close()
        }
    }

    @Test func renderSettings() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(filePath: try #require(environment["DESK_SNAPSHOT_DIR"]), directoryHint: .isDirectory)
        let source = URL(filePath: try #require(environment["DESK_SNAPSHOT_THREADS"]), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let threads = FileManager.default.temporaryDirectory.appending(path: "desk-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: threads)
        defer { try? FileManager.default.removeItem(at: threads) }
        let defaults = try #require(UserDefaults(suiteName: "desk-snapshot-\(UUID().uuidString)"))
        let catalog = ModelCatalog()
        let model = DeskModel(
            store: ThreadStore(directory: threads),
            runner: StallingRunner(),
            trash: { _ in },
            defaults: defaults,
            catalog: catalog,
            supportDirectory: ThreadStore.supportDirectory,
            assumeInstalled: false,
            accountPicture: { AccountPicture.load() },
            takibi: TakibiService()
        )
        await catalog.refresh()
        await model.takibi.refresh()
        await model.refreshSignIn()
        await model.refreshTools()
        model.setKeyFile("/tmp/desk-snapshot-codex.key", for: .codex)
        let tabs: [(String, AnyView)] = [
            ("settings-general", AnyView(GeneralSettings(model: model))),
            ("settings-agents", AnyView(AgentsSettings(model: model))),
            ("settings-permissions", AnyView(PermissionsSettings(model: model))),
            ("settings-tools", AnyView(ToolsSettings(model: model))),
            ("settings-tags", AnyView(TagsSettings(model: model))),
            ("settings-takibi", AnyView(TakibiSettings(model: model))),
        ]
        for (name, view) in tabs {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: name == "settings-agents" || name == "settings-takibi" ? 1500 : 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(900))
            let content = try #require(window.contentView)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "\(name).png"))
            window.close()
        }
    }

    /// The README's screenshots, at one window size, with the demo threads and their `.desk` folder.
    @Test func renderReadme() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(filePath: try #require(environment["DESK_SNAPSHOT_DIR"]), directoryHint: .isDirectory)
        let source = URL(filePath: try #require(environment["DESK_SNAPSHOT_THREADS"]), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let catalog = ModelCatalog()
        await catalog.refresh()
        let states: [(name: String, dark: Bool, tag: String?, thread: String?, ask: String?)] = [
            ("roundtable", false, nil, nil, nil),
            ("roundtable-dark", true, nil, nil, nil),
            ("approval", false, nil, "Tidewater waitlist survey", "@claude Chart the waits by weekday for the board deck."),
            ("tags", false, "Lumen Bikes", "Dealer FAQ rewrite", nil),
        ]
        for state in states {
            let threads = FileManager.default.temporaryDirectory.appending(path: "desk-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: source, to: threads)
            defer { try? FileManager.default.removeItem(at: threads) }
            let defaults = try #require(UserDefaults(suiteName: "desk-snapshot-\(UUID().uuidString)"))
            defaults.set("Sam", forKey: "profile.name")
            defaults.set(true, forKey: DeskModel.welcomeKey)
            let model = DeskModel(store: ThreadStore(directory: threads), runner: ApprovingRunner(), trash: { _ in }, defaults: defaults, catalog: catalog)
            model.tagFilter = state.tag
            if let title = state.thread {
                model.selection = model.threads.first { $0.title == title }?.id
            }
            if let ask = state.ask {
                model.draft = ask
                model.send()
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1400, height: 960),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
            NSApp.appearance = window.appearance
            window.contentView = NSHostingView(rootView: ContentView(model: model))
            window.orderFront(nil)
            window.center()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(1000))
            splitView(in: window.contentView)?.setPosition(250, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(1500))
            try screenshot(window, to: output.appending(path: "\(state.name).png"))
            model.stop()
            window.close()
        }
    }

    /// Settings → Takibi and the welcome window, with every agent signed in.
    @Test func renderReadmeWindows() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(filePath: try #require(environment["DESK_SNAPSHOT_DIR"]), directoryHint: .isDirectory)
        let source = URL(filePath: try #require(environment["DESK_SNAPSHOT_THREADS"]), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let threads = FileManager.default.temporaryDirectory.appending(path: "desk-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: threads)
        defer { try? FileManager.default.removeItem(at: threads) }
        let defaults = try #require(UserDefaults(suiteName: "desk-snapshot-\(UUID().uuidString)"))
        let catalog = ModelCatalog()
        let model = DeskModel(
            store: ThreadStore(directory: threads),
            runner: StallingRunner(),
            trash: { _ in },
            defaults: defaults,
            catalog: catalog,
            assumeInstalled: false,
            takibi: TakibiService(),
            signInProbe: { executable, _ in
                switch executable.lastPathComponent {
                case "claude": SignInOutput(stdout: #"{"loggedIn":true,"authMethod":"claude.ai"}"#, exitCode: 0, stderr: "")
                case "codex": SignInOutput(stdout: "Logged in using ChatGPT", exitCode: 0, stderr: "")
                default: SignInOutput(stdout: "Logged in", exitCode: 0, stderr: "")
                }
            }
        )
        await catalog.refresh()
        await model.takibi.refresh()
        await model.refreshSignIn()
        for agent in AgentID.allCases {
            model.setKeyFile(threads.appending(path: "\(agent.rawValue).key").path(percentEncoded: false), for: agent)
        }
        let windows: [(String, AnyView, NSWindow.StyleMask)] = [
            // Only the Settings scene shows the tabs, so the pane goes in a window titled like it.
            ("settings", AnyView(TakibiSettings(model: model).frame(width: 520)), [.titled, .closable]),
            ("welcome", AnyView(WelcomeView(model: model)), [.titled, .closable, .fullSizeContentView]),
        ]
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        for (name, view, style) in windows {
            let window = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = name == "settings" ? "Takibi" : ""
            window.titlebarAppearsTransparent = name == "welcome"
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: 520, height: 600))
            window.center()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(2500))
            try screenshot(window, to: output.appending(path: "\(name).png"))
            window.close()
        }
    }
}

/// The window server's copy, since caching the view skips the sidebar's list and the title bar.
@MainActor
private func screenshot(_ window: NSWindow, to url: URL) throws {
    let capture = Process()
    capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
    capture.arguments = ["-o", "-x", "-l", "\(window.windowNumber)", url.path(percentEncoded: false)]
    try capture.run()
    capture.waitUntilExit()
}

@MainActor
private func splitView(in view: NSView?) -> NSSplitView? {
    guard let view else { return nil }
    if let split = view as? NSSplitView { return split }
    return view.subviews.lazy.compactMap { splitView(in: $0) }.first
}

/// Reads the file, then asks to run a script and waits until it's cancelled.
private struct ApprovingRunner: AgentRunner {
    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let command = "python3 chart_waits.py --input survey.csv --by weekday --out wait-times.png"
            continuation.yield(.model("claude-opus-5-5"))
            continuation.yield(.stepStarted(WorkStep.tool(id: "r", name: "Read", input: ["file_path": "survey.csv"])))
            continuation.yield(.stepFinished(id: "r", failed: false))
            continuation.yield(.stepStarted(WorkStep.fileWrite(id: "w", path: "chart_waits.py")))
            continuation.yield(.stepFinished(id: "w", failed: false))
            continuation.yield(.stepStarted(.command(id: "c", command)))
            let task = Task {
                _ = await approve(.claude(id: "1", tool: "Bash", input: ["command": command]))
                try? await Task.sleep(for: .seconds(600))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Reports a model and a tool call, then waits until it's cancelled.
private struct StallingRunner: AgentRunner {
    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.model("claude-opus-5-5"))
            continuation.yield(.stepStarted(.thinking(id: "t")))
            continuation.yield(.thinking("Check the beta numbers in Takibi before answering."))
            continuation.yield(.stepFinished(id: "t", failed: false))
            continuation.yield(.stepStarted(.command(id: "c", #"takibi ask -q "weekly asks per workspace""#)))
            continuation.yield(.activity("Running `takibi ask -q \"weekly asks per workspace\"`"))
            let task = Task {
                try? await Task.sleep(for: .seconds(600))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
