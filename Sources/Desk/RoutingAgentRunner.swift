import Foundation

struct RoutingAgentRunner: AgentRunner {
    var claude = ClaudeAgentRunner()
    var codex = CodexAgentRunner()
    var grok = GrokAgentRunner()
    var muse = MuseAgentRunner()

    func runner(for agent: AgentID) -> any AgentRunner {
        switch agent {
        case .claude: claude
        case .codex: codex
        case .grok: grok
        case .muse: muse
        }
    }

    func run(
        agent: AgentID,
        prompt: String,
        session: String?,
        workspace: URL,
        model: String?,
        effort: String? = nil,
        permissions: AgentPermissions = .standard,
        executable: URL? = nil,
        approve: @escaping ApprovalHandler = { _ in .deny }
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        runner(for: agent).run(
            agent: agent,
            prompt: prompt,
            session: session,
            workspace: workspace,
            model: model,
            effort: effort,
            permissions: permissions,
            executable: executable,
            approve: approve
        )
    }
}
