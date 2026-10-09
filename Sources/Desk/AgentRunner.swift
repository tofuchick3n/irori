import Foundation

enum AgentEvent: Equatable, Sendable {
    case text(String)
    case notice(String)
    case session(String)
    case model(String)
    case activity(String?)
    case stepStarted(WorkStep)
    case stepFinished(id: String, failed: Bool)
    /// Visible reasoning text, appended to the reply's thinking.
    case thinking(String)
    /// A tool the CLI refused; `command` is the shell command or a short summary of the input.
    case denied(tool: String, command: String?)
}

struct AgentPermissions: Equatable, Sendable {
    var allowsFileWrites: Bool
    var allowedCommands: [String]
    /// Expanded path passed to the agent as `TAKIBI_KEY_FILE`. Nil leaves the CLI's own key.
    var keyFile: String? = nil
    /// Tool rules Desk already allows, so Claude never asks about them.
    var allowedRules: [String] = []
    /// Images to hand the agent natively on this turn, as absolute paths.
    var images: [URL] = []

    static let standard = AgentPermissions(allowsFileWrites: true, allowedCommands: ["takibi"])
}

protocol AgentRunner: Sendable {
    func run(
        agent: AgentID,
        prompt: String,
        session: String?,
        workspace: URL,
        model: String?,
        effort: String?,
        permissions: AgentPermissions,
        executable: URL?,
        approve: @escaping ApprovalHandler
    ) -> AsyncThrowingStream<AgentEvent, Error>
}

protocol AgentLineParser: Sendable {
    mutating func events(from line: String) throws -> [AgentEvent]
    var finishedCleanly: Bool { get }
    mutating func sessionStarted()
}

extension AgentLineParser {
    mutating func sessionStarted() {}
}

struct AgentRunError: Error, LocalizedError, Equatable, Sendable {
    var message: String
    /// The stored CLI session is gone. Desk clears it and retries the turn once.
    var missingSession = false
    /// The CLI could not be found, so signing in won't help.
    var notInstalled = false

    var errorDescription: String? { message }
}
