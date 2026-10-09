import Foundation

struct ClaudeAgentRunner: AgentRunner {
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
        approve: @escaping ApprovalHandler = { _ in .deny }
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let stdin = AgentStdin()
        return AgentProcess(
            label: "claude",
            executable: executable ?? override,
            candidates: ClaudeCommand.candidatePaths(),
            arguments: ClaudeCommand.arguments(
                session: session,
                model: model,
                effort: effort,
                allowsFileWrites: permissions.allowsFileWrites,
                allowedCommands: permissions.allowedCommands,
                allowedRules: permissions.allowedRules
            ),
            environment: AgentCommand.environment(keyFile: permissions.keyFile),
            workspace: workspace,
            notFound: "claude was not found in ~/.local/bin, /opt/homebrew/bin, or /usr/local/bin.",
            missingSessionMarkers: [ClaudeCommand.missingSessionMarker],
            stdin: stdin
        ).run { ClaudeSession(stdin: stdin, prompt: prompt, images: permissions.images, approve: approve) }
    }
}
