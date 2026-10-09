import Foundation
import Testing
@testable import Desk

/// Lists each real CLI's MCP servers and skills. Read-only: adds and removes nothing.
/// Opt in with `DESK_LIVE=1 swift test --disable-sandbox --filter LiveTools`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1"))
struct LiveToolsTests {
    @Test func listsEveryAgentsServersAndSkills() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "desk-live-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DeskModel(
            store: ThreadStore(directory: directory),
            runner: EchoAgentRunner(),
            defaults: UserDefaults(suiteName: "desk-live-tools-\(UUID().uuidString)")!
        )
        model.refreshAvailability()
        await model.refreshTools()
        for agent in model.activeAgents {
            let tools = try #require(model.tools[agent])
            print("\(agent.displayName): \(tools.servers.map { "\($0.name) [\($0.status.label)]" }) · \(tools.skills.count) skills · error: \(tools.error ?? "none")")
            #expect(tools.error == nil)
        }
    }
}
