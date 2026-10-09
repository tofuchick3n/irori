import Foundation
import Testing
@testable import Desk

/// Runs the real agent CLIs, in parallel to stress the process layer.
/// Opt in with `DESK_LIVE=1 swift test --disable-sandbox --filter Live`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1"))
struct LiveAgentTests {
    @Test(arguments: AgentID.allCases)
    func repliesThenResumes(_ agent: AgentID) async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "desk-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = RoutingAgentRunner()

        let first = try await collect(runner.run(agent: agent, prompt: "User: Reply with exactly the word pelican.", session: nil, workspace: workspace, model: nil))
        #expect(first.text.lowercased().contains("pelican"))
        let session = try #require(first.session)

        let second = try await collect(runner.run(agent: agent, prompt: "User: Which word did I ask you to reply with? Answer with that word only.", session: session, workspace: workspace, model: nil))
        #expect(second.text.lowercased().contains("pelican"))
    }

    @Test(arguments: AgentID.allCases)
    func reportsAMissingSession(_ agent: AgentID) async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "desk-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stream = RoutingAgentRunner().run(agent: agent, prompt: "User: hi", session: UUID().uuidString.lowercased(), workspace: workspace, model: nil)
        await #expect(throws: AgentRunError.self) {
            do {
                _ = try await collect(stream)
            } catch let error as AgentRunError {
                #expect(error.missingSession, "\(agent): \(error.message)")
                throw error
            }
        }
    }

    @Test(arguments: AgentID.allCases)
    func acceptsAnEffortLevel(_ agent: AgentID) async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "desk-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let result = try await collect(RoutingAgentRunner().run(
            agent: agent,
            prompt: "User: Reply with exactly the word heron.",
            session: nil,
            workspace: workspace,
            model: nil,
            effort: "low"
        ))
        #expect(result.text.lowercased().contains("heron"), "\(agent) with low effort said: \(result.text)")
    }

    private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> (text: String, session: String?, notices: [String]) {
        var text = ""
        var session: String?
        var notices: [String] = []
        for try await event in stream {
            switch event {
            case .text(let chunk): text += chunk
            case .session(let id): session = id
            case .notice(let notice): notices.append(notice)
            case .denied(let tool, let command): notices.append("\(tool): \(command ?? "")")
            case .model, .activity, .stepStarted, .stepFinished, .thinking: break
            }
        }
        return (text, session, notices)
    }
}
