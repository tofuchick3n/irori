import Foundation

/// One JSON line in, zero or more events out. Shared by Claude and Grok.
struct ClaudeStreamParser: AgentLineParser {
    var agentName: String
    private var emittedText = false
    private var reportedModel: String?
    /// The current content block has already emitted its first text delta.
    private var clearedThisBlock = false
    private(set) var sawResult = false
    /// Content block index → step id, for thinking blocks still open.
    private var thinkingBlocks: [Int: String] = [:]
    private var thinkingCount = 0
    private var emittedThinking = false
    /// A new thinking block started after earlier thinking text; its first text gets a paragraph break.
    private var thinkingNeedsBreak = false
    private var startedTools: Set<String> = []
    /// Tools the person denied in Desk this turn; the result's denial list repeats them.
    var deniedInDesk: DeniedToolUses?

    init(agentName: String = "Claude") {
        self.agentName = agentName
    }

    var finishedCleanly: Bool { sawResult }

    mutating func events(from line: String) throws -> [AgentEvent] {
        guard let object = jsonObject(from: line) else { return [] }
        switch object["type"] as? String {
        case "system":
            return sessionEvent(object)
        case "stream_event":
            return textEvents(object["event"] as? [String: Any])
        case "assistant":
            return assistantEvents(object["message"] as? [String: Any])
        case "user":
            return toolResults(object["message"] as? [String: Any])
        case "result":
            sawResult = true
            if Self.isTrue(object["is_error"]) {
                throw AgentRunError(message: Self.failureText(object["result"], agentName: agentName))
            }
            return denialEvents(object["permission_denials"])
        default:
            return []
        }
    }

    private mutating func sessionEvent(_ object: [String: Any]) -> [AgentEvent] {
        guard (object["subtype"] as? String) == "init" else { return [] }
        var events: [AgentEvent] = []
        if let session = nonemptyString(object["session_id"]) {
            events.append(.session(session))
        }
        if let model = modelChange(object["model"]) {
            events.append(model)
        }
        return events
    }

    private mutating func textEvents(_ event: [String: Any]?) -> [AgentEvent] {
        guard let event else { return [] }
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            if let model = modelChange(message?["model"]) {
                return [model]
            }
            return []
        case "content_block_start":
            clearedThisBlock = false
            guard let block = event["content_block"] as? [String: Any] else { return [] }
            switch block["type"] as? String {
            case "thinking":
                thinkingCount += 1
                thinkingNeedsBreak = emittedThinking
                let id = "thinking-\(thinkingCount)"
                if let index = event["index"] as? Int {
                    thinkingBlocks[index] = id
                }
                return [.activity("Thinking"), .stepStarted(.thinking(id: id))]
            case "text" where emittedText:
                return [.text("\n\n")]
            default:
                return []
            }
        case "content_block_stop":
            guard let index = event["index"] as? Int, let id = thinkingBlocks.removeValue(forKey: index) else { return [] }
            return [.stepFinished(id: id, failed: false)]
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], (delta["type"] as? String) == "thinking_delta" {
                guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
                defer {
                    emittedThinking = true
                    thinkingNeedsBreak = false
                }
                return [.thinking(thinkingNeedsBreak ? "\n\n" + text : text)]
            }
            guard let delta = event["delta"] as? [String: Any],
                  (delta["type"] as? String) == "text_delta",
                  let text = delta["text"] as? String,
                  !text.isEmpty else {
                return []
            }
            var events: [AgentEvent] = []
            if !clearedThisBlock {
                clearedThisBlock = true
                events.append(.activity(nil))
            }
            emittedText = true
            events.append(.text(text))
            return events
        default:
            return []
        }
    }

    private mutating func assistantEvents(_ message: [String: Any]?) -> [AgentEvent] {
        guard let message else { return [] }
        var events: [AgentEvent] = []
        if let model = modelChange(message["model"]) {
            events.append(model)
        }
        let content = message["content"] as? [[String: Any]] ?? []
        for block in content where (block["type"] as? String) == "tool_use" {
            let name = nonemptyString(block["name"]) ?? "tool"
            let input = block["input"] as? [String: Any]
            if name == "Bash", let command = nonemptyString(input?["command"]) {
                events.append(.activity("Running `\(command)`"))
            } else {
                events.append(.activity("Using \(name)"))
            }
            let id = nonemptyString(block["id"]) ?? "tool-\(startedTools.count + 1)"
            if startedTools.insert(id).inserted {
                events.append(.stepStarted(.tool(id: id, name: name, input: input)))
            }
        }
        return events
    }

    private func toolResults(_ message: [String: Any]?) -> [AgentEvent] {
        let content = message?["content"] as? [[String: Any]] ?? []
        return content.compactMap { block in
            guard (block["type"] as? String) == "tool_result", let id = nonemptyString(block["tool_use_id"]) else { return nil }
            return .stepFinished(id: id, failed: Self.isTrue(block["is_error"]))
        }
    }

    private mutating func modelChange(_ value: Any?) -> AgentEvent? {
        guard let id = nonemptyString(value), id != reportedModel else { return nil }
        reportedModel = id
        return .model(id)
    }

    private func denialEvents(_ value: Any?) -> [AgentEvent] {
        guard let denials = value as? [[String: Any]] else { return [] }
        return denials.compactMap { denial in
            if let id = nonemptyString(denial["tool_use_id"]), deniedInDesk?.contains(id) == true {
                return nil
            }
            let tool = (denial["tool_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "tool"
            let detail = Self.detail(denial["tool_input"])
            return AgentEvent.denied(tool: tool, command: detail.isEmpty ? nil : detail)
        }
    }

    private static func detail(_ input: Any?) -> String {
        guard let input, !(input is NSNull) else { return "" }
        if let object = input as? [String: Any],
           let command = object["command"] as? String,
           !command.isEmpty {
            return command
        }
        return shortJSON(input)
    }

    private static func shortJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              var json = String(data: data, encoding: .utf8) else {
            return ""
        }
        if json.count > 200 {
            json = String(json.prefix(200)) + "…"
        }
        return json
    }

    private static func isTrue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private static func failureText(_ value: Any?, agentName: String) -> String {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "\(agentName) failed."
    }
}
