import Foundation
import Testing
@testable import Desk

/// Runs each real agent through a command, a file read, and a file write, and prints the steps Desk would show.
/// Opt in with `DESK_LIVE_STEPS=1 swift test --disable-sandbox --filter LiveSteps`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE_STEPS"] == "1"))
struct LiveStepsTests {
    @Test(arguments: AgentID.allCases)
    func stepsFromARealRun(_ agent: AgentID) async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "desk-live-steps-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "The secret word is heron.".write(to: workspace.appending(path: "notes.md"), atomically: true, encoding: .utf8)

        let prompt = """
        User: Do these three things in order, then reply with one short line. \
        1) Run the shell command `takibi version`. \
        2) Read the file notes.md in your working directory. \
        3) Create the file out.md in your working directory containing the secret word from notes.md.
        """
        var steps: [String: WorkStep] = [:]
        var order: [String] = []
        var thinking = ""
        var text = ""
        var other: [String] = []
        for try await event in RoutingAgentRunner().run(agent: agent, prompt: prompt, session: nil, workspace: workspace, model: nil) {
            switch event {
            case .stepStarted(let step):
                if steps[step.id] == nil { order.append(step.id) }
                var merged = steps[step.id] ?? step
                merged.title = step.title
                merged.kind = step.kind
                steps[step.id] = merged
            case .stepFinished(let id, let failed):
                steps[id]?.state = failed ? .failed : .done
            case .thinking(let chunk): thinking += chunk
            case .text(let chunk): text += chunk
            case .notice(let notice): other.append("notice: \(notice)")
            case .denied(let tool, let command): other.append("denied: \(tool) \(command ?? "")")
            default: break
            }
        }
        let written = (try? String(contentsOf: workspace.appending(path: "out.md"), encoding: .utf8)) ?? "<missing>"
        print("STEPS \(agent) ---")
        for id in order {
            let step = steps[id]!
            print("STEPS \(agent)   [\(step.state.rawValue)] \(step.kind.rawValue): \(step.title)")
        }
        print("STEPS \(agent)   thinking: \(thinking.count) chars · reply: \(text.prefix(120).replacingOccurrences(of: "\n", with: " "))")
        print("STEPS \(agent)   out.md: \(written.prefix(80)) · \(other)")
        #expect(!order.isEmpty, "\(agent) reported no steps")
        #expect(!steps.values.contains { $0.state == .running }, "\(agent) left steps running")
    }
}
