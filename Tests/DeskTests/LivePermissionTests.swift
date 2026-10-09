import Foundation
import Testing
@testable import Desk

/// Checks the file-writing setting against the real CLIs.
/// Opt in with `DESK_LIVE=1 swift test --disable-sandbox --filter LivePermission`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1"))
struct LivePermissionTests {
    @Test(arguments: AgentID.allCases, [true, false])
    func fileWritesFollowTheSetting(_ agent: AgentID, allowed: Bool) async throws {
        // Not under the temp folder: sandboxes allow temp writes even when read-only.
        let workspace = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/desk-perm-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stream = RoutingAgentRunner().run(
            agent: agent,
            prompt: "User: Create a file named note.txt in the current directory containing the word heron. Use your file or shell tools; do not ask.",
            session: nil,
            workspace: workspace,
            model: nil,
            effort: "low",
            permissions: AgentPermissions(allowsFileWrites: allowed, allowedCommands: ["takibi"]),
            executable: nil
        )
        for try await _ in stream {}
        let exists = FileManager.default.fileExists(atPath: workspace.appending(path: "note.txt").path(percentEncoded: false))
        #expect(exists == allowed, "\(agent) with writes \(allowed ? "on" : "off") \(exists ? "created" : "did not create") note.txt")
    }
}
