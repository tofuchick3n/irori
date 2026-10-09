import AppKit
import SwiftUI
import Testing
@testable import Desk

/// Text views must lay out at their own width after SwiftUI's size probes, including when the
/// transcript is rebuilt for another thread.
@MainActor
struct MarkdownTextLayoutTests {
    private func thread(_ bodies: [String]) -> Desk.Thread {
        var thread = Desk.Thread(title: "t")
        thread.messages = bodies.map { Message(author: .agent(.claude), body: $0) }
        return thread
    }

    private func transcript(_ thread: Desk.Thread) -> TranscriptView {
        TranscriptView(thread: thread, streamingMessageID: nil, modelLabel: { id, _ in id }, userName: "You", userPhoto: nil,
                       saveToTakibi: { _ in }, workspace: FileManager.default.temporaryDirectory, allowedCommands: [], allowCommand: { _ in })
    }

    private func textViews(in view: NSView) -> [MarkdownTextView] {
        (view as? MarkdownTextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    @Test func textLaysOutAtItsOwnWidthAfterSwitchingThreads() async throws {
        _ = NSApplication.shared
        let first = thread(["A short reply about the blog prune plan.", "## Plan\n\n- keep\n- redirect"])
        let second = thread(["Another thread's reply, long enough to wrap across a couple of lines when the column is narrow enough to matter here.", "Second"])
        let host = NSHostingView(rootView: AnyView(transcript(first).id(first.id)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for rootThread in [first, second, first] {
            host.rootView = AnyView(transcript(rootThread).id(rootThread.id))
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let views = textViews(in: host)
            #expect(views.count == 2)
            for view in views {
                #expect(view.bounds.width > 300, "text view is \(view.bounds.width) wide")
                #expect(abs((view.textContainer?.size.width ?? 0) - view.bounds.width) < 1,
                        "lays out at \(view.textContainer?.size.width ?? 0) inside \(view.bounds.width)")
            }
        }
    }

    @Test func textFitsInsideTheViewsInset() {
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.textContainerInset = NSSize(width: 18, height: 16)
        view.setFrameSize(NSSize(width: 400, height: 300))
        #expect(view.textContainer?.size.width == 364)
    }
}
