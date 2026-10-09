import Foundation

struct CodexStreamParser: AgentLineParser {
    private var emittedText = false
    private(set) var finishedCleanly = false

    mutating func events(from line: String) throws -> [AgentEvent] {
        guard let object = jsonObject(from: line) else { return [] }
        switch object["type"] as? String {
        case "thread.started":
            guard let id = object["thread_id"] as? String, !id.isEmpty else { return [] }
            return [.session(id)]
        case "item.completed":
            return textEvents(object["item"] as? [String: Any])
        case "turn.completed":
            finishedCleanly = true
            return []
        case "turn.failed":
            throw AgentRunError(message: Self.failure(object["error"]))
        case "error":
            throw AgentRunError(message: Self.plain(object["message"]) ?? "Codex failed.")
        default:
            return []
        }
    }

    private mutating func textEvents(_ item: [String: Any]?) -> [AgentEvent] {
        guard let item, (item["type"] as? String) == "agent_message" else { return [] }
        guard let text = item["text"] as? String, !text.isEmpty else { return [] }
        var events: [AgentEvent] = []
        if emittedText {
            events.append(.text("\n\n"))
        }
        emittedText = true
        events.append(.text(text))
        return events
    }

    private static func failure(_ error: Any?) -> String {
        if let object = error as? [String: Any], let message = plain(object["message"]) {
            return message
        }
        if let message = plain(error) {
            return message
        }
        return "Codex failed."
    }

    private static func plain(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
