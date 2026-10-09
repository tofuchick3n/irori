import AppKit
import SwiftUI
import Testing
@testable import Desk

/// Hosts the real window, so it's opt-in: `DESK_WINDOW_TESTS=1 swift test --disable-sandbox --filter SidebarControl`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_WINDOW_TESTS"] == "1"))
struct SidebarControlTests {
    @Test func dragCannotCollapseButTheToggleAnimatesBothWays() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "desk-sidebar-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = SidebarControl()
        let model = DeskModel(store: ThreadStore(directory: directory), trash: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: ContentView(model: model, sidebar: control))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(800))

        let split = try #require(Self.splitView(in: window.contentView!)?.delegate as? NSSplitViewController)
        let sidebar = try #require(split.splitViewItems.first)
        #expect(sidebar.canCollapse == false)

        control.toggle()
        try await Task.sleep(for: .milliseconds(600))
        #expect(sidebar.isCollapsed)

        control.toggle()
        try await Task.sleep(for: .milliseconds(600))
        #expect(!sidebar.isCollapsed)
        #expect(sidebar.canCollapse == false)
    }

    @Test func openingFilesInANarrowWindowHidesTheSidebarInsteadOfWidening() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "desk-sidebar-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = SidebarControl()
        let model = DeskModel(store: ThreadStore(directory: directory), trash: { _ in })
        model.newThread()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: ContentView(model: model, sidebar: control))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(800))
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: true)
        try await Task.sleep(for: .milliseconds(300))
        let sidebar = try #require((Self.splitView(in: window.contentView!)?.delegate as? NSSplitViewController)?.splitViewItems.first)
        let width = window.frame.width

        model.showsFiles = true
        try await Task.sleep(for: .milliseconds(800))
        #expect(sidebar.isCollapsed)
        #expect(window.frame.width == width, "\(width) -> \(window.frame.width)")

        model.showsFiles = false
        try await Task.sleep(for: .milliseconds(800))
        #expect(!sidebar.isCollapsed)
    }

    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = splitView(in: subview) { return found }
        }
        return nil
    }
}
