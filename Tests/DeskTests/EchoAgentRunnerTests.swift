import Foundation
import Testing
@testable import Desk

@Test func echoUsesAFortyMillisecondWordDelay() {
    #expect(EchoAgentRunner().wordDelay == .milliseconds(40))
}

@Test func echoStreamsTheLastUserLineWordByWord() async throws {
    let runner = EchoAgentRunner(wordDelay: .milliseconds(1))
    let prompt = """
    User: @grok @claude hi
    Grok: earlier
    """
    var text = ""
    for try await event in runner.run(agent: .claude, prompt: prompt, session: "ignored", workspace: URL(filePath: "/"), model: nil) {
        guard case .text(let chunk) = event else {
            Issue.record("unexpected event")
            continue
        }
        text += chunk
    }
    #expect(text == "**Claude** heard: @grok @claude hi")
}

@Test func echoHonorsCancellation() async throws {
    let runner = EchoAgentRunner(wordDelay: .seconds(10))
    let prompt = "User: alpha beta gamma delta epsilon"
    let stream = runner.run(agent: .grok, prompt: prompt, session: nil, workspace: URL(filePath: "/"), model: nil)
    let clock = ContinuousClock()
    let started = clock.now
    let task = Task {
        var text = ""
        do {
            for try await event in stream {
                if case .text(let chunk) = event {
                    text += chunk
                }
            }
        } catch is CancellationError {
            return text
        }
        return text
    }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let text = try await task.value
    #expect(text == "**Grok**")
    #expect(clock.now - started < .seconds(2))
}
