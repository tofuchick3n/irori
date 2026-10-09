import Foundation

/// One Claude turn over stream-json input. Sends the prompt, answers `can_use_tool` requests
/// through the approval handler, and reads the reply with `ClaudeStreamParser`.
struct ClaudeSession: AgentLineParser {
    var stdin: AgentStdin
    var prompt: String
    var images: [URL] = []
    var approve: ApprovalHandler
    private var parser = ClaudeStreamParser()
    private let deniedInDesk = DeniedToolUses()

    private var pendingNotices: [AgentEvent] = []

    init(stdin: AgentStdin, prompt: String, images: [URL] = [], approve: @escaping ApprovalHandler) {
        self.stdin = stdin
        self.prompt = prompt
        self.images = images
        self.approve = approve
        parser.deniedInDesk = deniedInDesk
    }

    var finishedCleanly: Bool { parser.finishedCleanly }

    mutating func sessionStarted() {
        stdin.write(ClaudeCommand.initializeRequest())
        let message = ClaudeCommand.userMessage(prompt, images: images)
        stdin.write(message.line)
        if !message.skipped.isEmpty {
            pendingNotices = [.notice(Attachments.skippedNotice(message.skipped))]
        }
    }

    mutating func events(from line: String) throws -> [AgentEvent] {
        let notices = pendingNotices
        pendingNotices = []
        return try notices + reply(to: line)
    }

    private mutating func reply(to line: String) throws -> [AgentEvent] {
        guard let object = jsonObject(from: line) else { return [] }
        switch object["type"] as? String {
        case "control_request":
            answer(object)
            return []
        case "control_response":
            return []
        default:
            return try parser.events(from: line)
        }
    }

    private func answer(_ object: [String: Any]) {
        guard let requestID = nonemptyString(object["request_id"]),
              let request = object["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool",
              let tool = nonemptyString(request["tool_name"]) else { return }
        let input = request["input"] as? [String: Any] ?? [:]
        let toolUseID = nonemptyString(request["tool_use_id"])
        let allow = ClaudeCommand.controlResponse(requestID: requestID, input: input, allow: true)
        let deny = ClaudeCommand.controlResponse(requestID: requestID, input: input, allow: false)
        let approval = ApprovalRequest.claude(id: requestID, tool: tool, input: input)
        let stdin = stdin
        let approve = approve
        let deniedInDesk = deniedInDesk
        Task {
            let decision = await approve(approval)
            if !decision.allows, let toolUseID {
                deniedInDesk.insert(toolUseID)
            }
            stdin.write(decision.allows ? allow : deny)
        }
    }
}
