import Foundation

struct EchoAgentRunner: AgentRunner {
    var wordDelay: Duration = .milliseconds(40)

    func run(
        agent: AgentID,
        prompt: String,
        session _: String?,
        workspace _: URL,
        model _: String?,
        effort _: String? = nil,
        permissions _: AgentPermissions = .standard,
        executable _: URL? = nil,
        approve _: @escaping ApprovalHandler = { _ in .deny }
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let phrase = "**\(agent.displayName)** heard: \(Turn.lastUserLine(in: prompt))"
        let words = phrase.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let delay = wordDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for (index, word) in words.enumerated() {
                        try Task.checkCancellation()
                        continuation.yield(.text(index == 0 ? word : " \(word)"))
                        if index + 1 < words.count {
                            try await Task.sleep(for: delay)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
