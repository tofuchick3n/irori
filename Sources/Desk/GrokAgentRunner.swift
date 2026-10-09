import Foundation

struct GrokAgentRunner: AgentRunner {
    var executable: URL?

    func run(
        agent _: AgentID,
        prompt: String,
        session: String?,
        workspace: URL,
        model: String?,
        effort: String? = nil,
        permissions: AgentPermissions = .standard,
        executable override: URL? = nil,
        approve _: @escaping ApprovalHandler = { _ in .deny }
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AgentProcess(
            label: "grok",
            executable: executable ?? override,
            candidates: GrokCommand.candidatePaths(),
            arguments: GrokCommand.arguments(
                prompt: prompt,
                session: session,
                workspace: workspace,
                model: model,
                effort: effort,
                allowsFileWrites: permissions.allowsFileWrites
            ),
            environment: AgentCommand.environment(keyFile: permissions.keyFile),
            workspace: workspace,
            notFound: "grok was not found in ~/.local/bin, /opt/homebrew/bin, or /usr/local/bin.",
            missingSessionMarkers: [GrokCommand.missingSessionMarker]
        ).run { ClaudeStreamParser(agentName: "Grok") }
    }
}
