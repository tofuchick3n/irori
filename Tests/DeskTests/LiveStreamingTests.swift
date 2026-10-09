import Foundation
import Testing
@testable import Desk

/// Measures how a real reply streams through Desk's runners.
/// Opt in with `DESK_LIVE_TIMING=1 swift test --disable-sandbox --filter LiveStreaming`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE_TIMING"] == "1"))
struct LiveStreamingTests {
    @Test(arguments: AgentID.allCases)
    func streamsTextAsItArrives(_ agent: AgentID) async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "desk-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let clock = ContinuousClock()
        let start = clock.now
        var firstActivity: Duration?
        var activities: [String] = []
        var textTimes: [Duration] = []
        var model: String?
        let stream = RoutingAgentRunner().run(
            agent: agent,
            prompt: "User: Write about 250 words on why bonfires bring people together. Plain prose, no tools.",
            session: nil,
            workspace: workspace,
            model: nil
        )
        for try await event in stream {
            switch event {
            case .text: textTimes.append(clock.now - start)
            case .activity(let value?):
                activities.append(value)
                if firstActivity == nil { firstActivity = clock.now - start }
            case .model(let id): model = id
            default: break
            }
        }
        let first = try #require(textTimes.first)
        let spread = try #require(textTimes.last) - first
        print("TIMING \(agent): model \(model ?? "none") · first activity \(firstActivity.map { "\($0)" } ?? "none") \(activities.prefix(3)) · first text \(first) · \(textTimes.count) chunks over \(spread)")
        #expect(textTimes.count > 3, "\(agent) should stream in more than a few chunks")
    }
}
