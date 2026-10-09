import Foundation

struct MuseAgentRunner: AgentRunner {
    var executable: URL?
    var sessionRoot: URL

    init(executable: URL? = nil, sessionRoot: URL? = nil) {
        self.executable = executable
        self.sessionRoot = sessionRoot ?? MuseCommand.sessionRoot()
    }

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
        if let session, !session.isEmpty, !MuseCommand.hasSessionDirectory(id: session, root: sessionRoot) {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AgentRunError(
                    message: "Muse's earlier session wasn't found.",
                    missingSession: true
                ))
            }
        }
        return AgentProcess(
            label: "muse",
            executable: executable ?? override,
            candidates: MuseCommand.candidatePaths(),
            arguments: MuseCommand.arguments(
                prompt: prompt,
                session: session,
                workspace: workspace,
                model: model,
                effort: effort,
                allowsFileWrites: permissions.allowsFileWrites,
                images: permissions.images
            ),
            environment: AgentCommand.environment(keyFile: permissions.keyFile),
            workspace: workspace,
            notFound: "muse was not found in ~/.local/bin, /opt/homebrew/bin, or /usr/local/bin."
        ).run { MuseStreamParser() }
    }
}
