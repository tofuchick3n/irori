import AppKit
import SwiftUI
import Testing
@testable import Desk

/// Hosts the real window, so it's opt-in: `DESK_WINDOW_TESTS=1 swift test --disable-sandbox --filter MentionKeys`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_WINDOW_TESTS"] == "1"))
struct MentionKeysTests {
    /// AppKit marks arrow keys with the numeric pad and function flags, which once read as modifiers.
    @Test func arrowKeysMoveThroughTheMentionList() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "desk-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "desk-keys-\(UUID().uuidString)"))
        let model = DeskModel(
            store: ThreadStore(directory: root.appending(path: "threads")),
            workspacesDirectory: root.appending(path: "workspaces"),
            trash: { _ in },
            defaults: defaults,
            supportDirectory: root
        )
        model.newThread()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: ContentView(model: model))
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(800))
        model.composerFocusRequest += 1
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("@", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(300))

        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        for _ in 0..<2 {
            window.sendEvent(try key(down, code: 125, flags: [.numericPad, .function], in: window))
            try await Task.sleep(for: .milliseconds(150))
        }
        window.sendEvent(try key("\r", code: 36, flags: [], in: window))
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.draft == "@grok ")
    }

    @Test func clickingAMentionInsertsIt() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "desk-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "desk-keys-\(UUID().uuidString)"))
        let model = DeskModel(
            store: ThreadStore(directory: root.appending(path: "threads")),
            workspacesDirectory: root.appending(path: "workspaces"),
            trash: { _ in },
            defaults: defaults,
            supportDirectory: root
        )
        model.newThread()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: ContentView(model: model))
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(800))
        model.composerFocusRequest += 1
        try await Task.sleep(for: .milliseconds(300))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("@", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(400))

        // Rows run up from just above the field: All, Muse, Grok, Codex, Claude.
        let field = editor.convert(editor.bounds, to: nil)
        let point = NSPoint(x: field.minX + 40, y: field.maxY + 4 + 8 + 5 + 24 * 3.5)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )))
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.draft == "@codex ")
    }

    @Test func escapeDismissesTheMentionListThenClosesTheFilesDrawer() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "desk-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try #require(UserDefaults(suiteName: "desk-keys-\(UUID().uuidString)"))
        let model = DeskModel(
            store: ThreadStore(directory: root.appending(path: "threads")),
            workspacesDirectory: root.appending(path: "workspaces"),
            trash: { _ in },
            defaults: defaults,
            supportDirectory: root
        )
        model.newThread()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 600), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: ContentView(model: model))
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(800))
        model.showsFiles = true
        model.composerFocusRequest += 1
        try await Task.sleep(for: .milliseconds(500))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("@", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(300))

        let escape = "\u{1B}"
        window.sendEvent(try key(escape, code: 53, flags: [], in: window))
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.showsFiles)
        window.sendEvent(try key(escape, code: 53, flags: [], in: window))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.showsFiles)
        #expect(model.draft == "@")
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }
}
