import Foundation

struct CodexAgentRunner: AgentRunner {
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
            label: "codex",
            executable: executable ?? override,
            candidates: CodexCommand.candidatePaths(),
            arguments: CodexCommand.arguments(),
            environment: AgentCommand.environment(keyFile: permissions.keyFile),
            workspace: workspace,
            notFound: "codex was not found in /opt/homebrew/bin, ~/.local/bin, or /usr/local/bin.",
            missingSessionMarkers: [CodexCommand.missingSessionMarker],
            stdin: stdin
        ).run {
            CodexAppServerSession(
                stdin: stdin,
                prompt: prompt,
                session: session,
                workspace: workspace,
                model: model,
                effort: effort,
                allowsFileWrites: permissions.allowsFileWrites,
                images: permissions.images,
                approve: approve
            )
        }
    }
}
