import Foundation
import Testing
@testable import Desk

@Test func claudeMissingSessionWinsOverTheErrorResult() async throws {
    let standIn = try StandIn(name: "claude", source: """
    #!/bin/bash
    echo 'No conversation found with session ID: abc' >&2
    echo '{"type":"result","is_error":true,"subtype":"error_during_execution","result":null}'
    exit 1
    """)
    defer { standIn.remove() }

    let error = try await runError(ClaudeAgentRunner(executable: standIn.executable), workspace: standIn.workspace)
    #expect(error.missingSession)
    #expect(error.message.contains("No conversation found with session ID"))
}

@Test func codexMissingSessionIsClassifiedFromStderr() async throws {
    let standIn = try StandIn(name: "codex", source: """
    #!/bin/bash
    echo 'thread/resume failed: no rollout found for thread id abc' >&2
    exit 1
    """)
    defer { standIn.remove() }

    let error = try await runError(CodexAgentRunner(executable: standIn.executable), workspace: standIn.workspace)
    #expect(error.missingSession)
    #expect(error.message.contains("no rollout found for thread id"))
}

@Test func grokMissingSessionIsClassifiedFromStderr() async throws {
    let standIn = try StandIn(name: "grok", source: """
    #!/bin/bash
    echo 'Session "abc" not found locally, restoring conversation from remote...' >&2
    echo 'Failed to restore session from remote: 404 Not Found' >&2
    exit 1
    """)
    defer { standIn.remove() }

    let error = try await runError(GrokAgentRunner(executable: standIn.executable), workspace: standIn.workspace)
    #expect(error.missingSession)
    #expect(error.message.contains("Failed to restore session"))
}

@Test func claudeParserErrorSurfacesWhenTheSessionIsNotMissing() async throws {
    let standIn = try StandIn(name: "claude", source: """
    #!/bin/bash
    echo 'ordinary failure' >&2
    echo '{"type":"result","is_error":true,"subtype":"error_during_execution","result":"rate limit"}'
    exit 1
    """)
    defer { standIn.remove() }

    let error = try await runError(ClaudeAgentRunner(executable: standIn.executable), workspace: standIn.workspace)
    #expect(error.missingSession == false)
    #expect(error.message == "rate limit")
}

@Test func aSuccessfulRunIgnoresAMissingSessionMarker() async throws {
    let standIn = try StandIn(name: "claude", source: """
    #!/bin/bash
    echo 'No conversation found with session ID: abc' >&2
    echo '{"type":"result","is_error":false}'
    exit 0
    """)
    defer { standIn.remove() }

    let stream = ClaudeAgentRunner(executable: standIn.executable).run(
        agent: .claude,
        prompt: "User: hi",
        session: "abc",
        workspace: standIn.workspace,
        model: nil
    )
    for try await _ in stream {}
}

@Test func museMissingSessionDoesNotSpawn() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "desk-muse-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appending(path: "sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions.appending(path: "gone", directoryHint: .isDirectory), withIntermediateDirectories: true)

    let standIn = try StandIn(name: "muse", source: """
    #!/bin/bash
    touch spawned
    exit 0
    """)
    defer { standIn.remove() }

    let runner = MuseAgentRunner(executable: standIn.executable, sessionRoot: sessions)
    let error = try await runError(runner, agent: .muse, workspace: standIn.workspace, session: "gone")
    #expect(error.missingSession)
    #expect(FileManager.default.fileExists(atPath: standIn.workspace.appending(path: "spawned").path(percentEncoded: false)) == false)
}

@Test func museSessionDirectorySpawns() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "desk-muse-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sessions = root.appending(path: "sessions", directoryHint: .isDirectory)
    let session = sessions.appending(path: "2026/10/05/sess-1", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let standIn = try StandIn(name: "muse", source: """
    #!/bin/bash
    touch spawned
    echo '{"payload":{"kind":"run_terminal","terminal":"completed"}}'
    exit 0
    """)
    defer { standIn.remove() }

    let runner = MuseAgentRunner(executable: standIn.executable, sessionRoot: sessions)
    let stream = runner.run(agent: .muse, prompt: "User: hi", session: "sess-1", workspace: standIn.workspace, model: nil)
    for try await _ in stream {}
    #expect(FileManager.default.fileExists(atPath: standIn.workspace.appending(path: "spawned").path(percentEncoded: false)))
}

@Test func missingSessionMarkerOutsideTheErrorTailStillMatches() async throws {
    let padding = String(repeating: "x", count: 3000)
    let standIn = try StandIn(name: "claude", source: """
    #!/bin/bash
    echo 'No conversation found with session ID: abc' >&2
    printf '%s\\n' '\(padding)' >&2
    echo '{"type":"result","is_error":true,"subtype":"error_during_execution","result":null}'
    exit 1
    """)
    defer { standIn.remove() }

    let error = try await runError(ClaudeAgentRunner(executable: standIn.executable), workspace: standIn.workspace)
    #expect(error.missingSession)
    #expect(error.message.count <= 2048)
    #expect(error.message.contains("No conversation found") == false)
    #expect(error.message.contains("x"))
}

@Test func museSessionRootIsUnderLocalShare() {
    let home = URL(filePath: "/Users/example")
    var path = MuseCommand.sessionRoot(home: home).path(percentEncoded: false)
    if path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    #expect(path == "/Users/example/.local/share/muse/sessions")
}

private struct StandIn {
    var root: URL
    var executable: URL
    var workspace: URL

    init(name: String, source: String) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "desk-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appending(path: name, directoryHint: .notDirectory)
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
        workspace = root.appending(path: "work", directoryHint: .isDirectory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func runError(
    _ runner: some AgentRunner,
    agent: AgentID = .claude,
    workspace: URL,
    session: String? = "abc"
) async throws -> AgentRunError {
    let stream = runner.run(
        agent: agent,
        prompt: "User: hi",
        session: session,
        workspace: workspace,
        model: nil,
        effort: nil,
        permissions: .standard,
        executable: nil,
        approve: { _ in .deny }
    )
    do {
        for try await _ in stream {}
        Issue.record("expected the run to fail")
        throw AgentRunError(message: "expected the run to fail")
    } catch let error as AgentRunError {
        return error
    }
}
