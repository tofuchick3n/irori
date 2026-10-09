import Foundation
import Testing
@testable import Desk

@MainActor
struct LiveReplyTests {
    @Test func deltasShowSoonAndReachTheThreadLater() async throws {
        var saved: [AgentEvent] = []
        let live = LiveReply(id: UUID()) { saved += $0 }
        let held = [live.hold(.text("Hel")), live.hold(.text("lo")), live.hold(.thinking("Plan"))]
        #expect(held == [true, true, true])
        #expect(live.text.isEmpty)

        var shownBeforeSaving = false
        for _ in 0..<300 where saved.isEmpty {
            if live.text == "Hello", live.thinking == "Plan" { shownBeforeSaving = true }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(shownBeforeSaving)
        #expect(saved == [.thinking("Plan"), .text("Hello")])
        #expect(live.text.isEmpty)
    }

    @Test func flushSavesHeldTextAtOnce() {
        var saved: [AgentEvent] = []
        let live = LiveReply(id: UUID()) { saved += $0 }
        let held = [live.hold(.text("partial")), live.hold(.activity("Thinking"))]
        #expect(held == [true, false])
        live.flush()
        #expect(saved == [.text("partial")])
        live.flush()
        #expect(saved == [.text("partial")])
    }

    @Test func shownMessageAddsTheLiveText() {
        let live = LiveReply(id: UUID()) { _ in }
        var message = Message(author: .agent(.codex), body: "Saved ")
        message.thinking = ""
        #expect(live.shown(message).body == "Saved ")
    }
}
