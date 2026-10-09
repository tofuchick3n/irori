import AppKit
import SwiftUI
import Testing
@testable import Desk

/// Scrolls a real thread on screen and times each frame's layout and drawing.
/// Opt in with `DESK_PERF_THREADS=<threads folder> swift test --disable-sandbox --filter ScrollPerformance`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_PERF_THREADS"] != nil))
struct ScrollPerformanceTests {
    @Test func scrollFrameTimes() async throws {
        let source = URL(filePath: try #require(ProcessInfo.processInfo.environment["DESK_PERF_THREADS"]), directoryHint: .isDirectory)
        let threads = FileManager.default.temporaryDirectory.appending(path: "desk-perf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: threads)
        defer { try? FileManager.default.removeItem(at: threads) }
        _ = NSApplication.shared

        let store = ThreadStore(directory: threads)
        let loaded = try store.load()
        let thread = try #require(loaded.max { $0.messages.reduce(0) { $0 + $1.body.count } < $1.messages.reduce(0) { $0 + $1.body.count } })
        let view = TranscriptView(
            thread: thread,
            streamingMessageID: nil,
            modelLabel: { id, _ in id },
            userName: "You",
            userPhoto: nil,
            saveToTakibi: { _ in },
            workspace: threads,
            allowedCommands: ["takibi"],
            allowCommand: { _ in }
        )
        let plain = ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(thread.messages) { Text($0.body).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(maxWidth: 720).padding(.horizontal, 24).frame(maxWidth: .infinity)
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ProcessInfo.processInfo.environment["DESK_PERF_PLAIN"] == "1"
            ? NSHostingView(rootView: AnyView(plain))
            : NSHostingView(rootView: AnyView(view))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))

        let content = try #require(window.contentView)
        let scrollView = try #require(Self.scrollView(in: content))
        let clip = scrollView.contentView
        var times: [Double] = []
        var jumps = 0
        // Three passes up and down in 24-point steps, like a trackpad.
        for pass in 0..<(ProcessInfo.processInfo.environment["DESK_PERF_PASSES"].flatMap(Int.init) ?? 6) {
            let height = (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height
            let up = pass % 2 == 0
            var y = up ? height : 0
            while up ? y > 0 : y < height {
                y += up ? -24 : 24
                let start = CACurrentMediaTime()
                let before = scrollView.documentView?.frame.height ?? 0
                clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
                scrollView.reflectScrolledClipView(clip)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                times.append((CACurrentMediaTime() - start) * 1000)
                if abs((scrollView.documentView?.frame.height ?? 0) - before) > 0.5 { jumps += 1 }
                await Task.yield()
            }
        }
        times.sort()
        let mean = times.reduce(0, +) / Double(times.count)
        let p95 = times[Int(Double(times.count) * 0.95)]
        let over = times.filter { $0 > 8.3 }.count
        print(String(format: "PERF \(thread.messages.count) messages · %d frames · mean %.2f ms · p95 %.2f ms · max %.2f ms · over 8.3 ms: %d · content height changed mid-scroll: %d times",
                     times.count, mean, p95, times.last ?? 0, over, jumps))
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}
