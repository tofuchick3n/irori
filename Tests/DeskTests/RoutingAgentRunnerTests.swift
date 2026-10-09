import Testing
@testable import Desk

@Test func routingSendsEachAgentToItsOwnRunner() {
    let routing = RoutingAgentRunner()
    #expect(routing.runner(for: .claude) is ClaudeAgentRunner)
    #expect(routing.runner(for: .codex) is CodexAgentRunner)
    #expect(routing.runner(for: .grok) is GrokAgentRunner)
    #expect(routing.runner(for: .muse) is MuseAgentRunner)
}
