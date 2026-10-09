import Foundation

struct MuseStreamParser: AgentLineParser {
    private var emittedSession = false
    private var emittedText = false
    private var clearedActivity = false
    private var reportedModel: String?
    private var thinkingOpen = false
    private var toolTasks: Set<String> = []
    private var namedTasks: Set<String> = []
    private(set) var finishedCleanly = false

    mutating func events(from line: String) throws -> [AgentEvent] {
        guard let object = jsonObject(from: line) else { return [] }
        var events: [AgentEvent] = []
        if !emittedSession,
           let stream = object["stream"] as? [String: Any],
           (stream["kind"] as? String) == "session",
           let id = nonemptyString(stream["id"]) {
            emittedSession = true
            events.append(.session(id))
        }

        let payload = object["payload"] as? [String: Any]
        let payloadType = object["payload_type"] as? String
        if payloadType == "run.model.configured", let id = nonemptyString(payload?["model_id"]), id != reportedModel {
            reportedModel = id
            events.append(.model(id))
        }
        // Muse reasons silently, often for 15 s or more, before any text arrives.
        if payloadType == "run.lifecycle.started", !emittedText {
            events.append(.activity("Thinking"))
            if !thinkingOpen {
                thinkingOpen = true
                events.append(.stepStarted(.thinking(id: "muse-thinking")))
            }
        }
        if payloadType == "task.lifecycle.proposed", let kind = Self.taskKind(payload), kind.hasPrefix("tool.") {
            let name = String(kind.dropFirst("tool.".count))
            events.append(.activity("Using \(name.isEmpty ? "tool" : name)"))
            if thinkingOpen {
                thinkingOpen = false
                events.append(.stepFinished(id: "muse-thinking", failed: false))
            }
            if let id = nonemptyString(payload?["task_id"]), toolTasks.insert(id).inserted {
                events.append(.stepStarted(.tool(id: id, name: name.isEmpty ? "tool" : name, input: nil)))
            }
        }
        // A bash task's output names its command; the step was opened before Muse said what it runs.
        if payloadType == "task.lifecycle.output", let id = nonemptyString(payload?["task_id"]), toolTasks.contains(id),
           !namedTasks.contains(id), let chunk = (payload?["event"] as? [String: Any])?["chunk"] as? String,
           let command = Self.command(inOutput: chunk) {
            namedTasks.insert(id)
            events.append(.stepStarted(.command(id: id, command)))
        }
        // Muse reports accepted, scheduled, started, output, and status before a task ends.
        if let payloadType, let id = nonemptyString(payload?["task_id"]), toolTasks.contains(id) {
            switch payloadType {
            case "task.lifecycle.completed":
                toolTasks.remove(id)
                events.append(.stepFinished(id: id, failed: false))
            case "task.lifecycle.failed", "task.lifecycle.rejected", "task.lifecycle.cancelled",
                 "task.lifecycle.canceled", "task.lifecycle.aborted", "task.lifecycle.timed_out":
                toolTasks.remove(id)
                events.append(.stepFinished(id: id, failed: true))
            default:
                break
            }
        }
        if payloadType == "run.output.delta", let text = payload?["text"] as? String, !text.isEmpty {
            if thinkingOpen {
                thinkingOpen = false
                events.append(.stepFinished(id: "muse-thinking", failed: false))
            }
            if !clearedActivity {
                clearedActivity = true
                events.append(.activity(nil))
            }
            emittedText = true
            events.append(.text(text))
        }

        if (payload?["kind"] as? String) == "run_terminal" {
            if (payload?["terminal"] as? String) == "completed" {
                finishedCleanly = true
                if !emittedText, let text = payload?["text"] as? String, !text.isEmpty {
                    emittedText = true
                    events.append(.text(text))
                }
            } else {
                throw AgentRunError(message: Self.failure(payload))
            }
        }
        return events
    }

    /// The `"command"` field in the start of a bash task's JSON output, which may be cut off mid-way.
    static func command(inOutput chunk: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""command"\s*:\s*"((?:[^"\\]|\\.)*)""#),
              let match = regex.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)),
              let range = Range(match.range(at: 1), in: chunk) else {
            return nil
        }
        let escaped = String(chunk[range])
        let decoded = (try? JSONSerialization.jsonObject(with: Data("\"\(escaped)\"".utf8), options: .fragmentsAllowed)) as? String
        return nonemptyString(decoded ?? escaped)
    }

    private static func taskKind(_ payload: [String: Any]?) -> String? {
        if let event = payload?["event"] as? [String: Any], let kind = nonemptyString(event["task_kind"]) {
            return kind
        }
        return nonemptyString(payload?["task_kind"])
    }

    private static func failure(_ payload: [String: Any]?) -> String {
        if let reason = payload?["reason"] as? String {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let text = payload?["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "Muse failed."
    }
}
