import Foundation
import Synchronization
import Testing
@testable import Desk

/// Asks the real Claude and Codex to do things that need an OK, and answers from the test.
/// Opt in with `DESK_LIVE=1 swift test --disable-sandbox --filter LiveApproval`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1"))
struct LiveApprovalTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "desk-live-approval-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func claudeAsksAndObeysTheAnswer() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let asked = Mutex<[ApprovalRequest]>([])
        let stream = ClaudeAgentRunner().run(
            agent: .claude,
            prompt: "User: Run the shell command `curl -sI https://example.com`. Then search the web for the Swift 6.2 release date. Reply in one short sentence.",
            session: nil,
            workspace: folder,
            model: nil,
            effort: nil,
            permissions: AgentPermissions(allowsFileWrites: true, allowedCommands: ["takibi"]),
            executable: nil,
            approve: { request in
                asked.withLock { $0.append(request) }
                return request.tool == "Bash" ? .deny : .allowOnce
            }
        )
        let result = try await collect(stream)
        let requests = asked.withLock { $0 }
        print("Claude asked:", requests.map(\.title))
        #expect(requests.contains { $0.rule == "Bash(curl:*)" })
        #expect(!result.text.isEmpty)
        #expect(result.session != nil)
    }

    @Test func codexRunsInsideItsSandboxAndAsksOutsideIt() async throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = FileManager.default.homeDirectoryForCurrentUser.appending(path: "desk-live-approval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        let asked = Mutex<[ApprovalRequest]>([])
        let stream = CodexAgentRunner().run(
            agent: .codex,
            prompt: "User: Run `touch inside.txt` in the current folder. Then run `touch \(outside.path(percentEncoded: false))`. Reply in one short sentence.",
            session: nil,
            workspace: folder,
            model: nil,
            effort: nil,
            permissions: AgentPermissions(allowsFileWrites: true, allowedCommands: ["takibi"]),
            executable: nil,
            approve: { request in
                asked.withLock { $0.append(request) }
                return .deny
            }
        )
        let result = try await collect(stream)
        let requests = asked.withLock { $0 }
        print("Codex asked:", requests.map(\.title))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "inside.txt").path(percentEncoded: false)))
        #expect(!requests.contains { $0.detail?.contains("inside.txt") == true })
        #expect(requests.contains { $0.detail?.contains(outside.lastPathComponent) == true })
        #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        #expect(!result.text.isEmpty)
    }

    private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> (text: String, session: String?) {
        var text = ""
        var session: String?
        for try await event in stream {
            switch event {
            case .text(let chunk): text += chunk
            case .session(let id): session = id
            default: break
            }
        }
        return (text, session)
    }
}
