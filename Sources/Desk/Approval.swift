import Foundation

struct ApprovalRequest: Sendable, Equatable {
    /// The CLI's request id, as text.
    var id: String
    /// "Bash", "WebSearch", "mcp__gmail__send_message". Codex commands are "Bash", file changes "Edit".
    var tool: String
    var title: String
    /// The full command or a short JSON of the input.
    var detail: String?
    /// What Allow in This Thread and Always Allow remember.
    var rule: String
}

enum ApprovalDecision: String, Codable, Sendable {
    case allowOnce, allowInThread, allowAlways, allowEverything, deny

    var allows: Bool { self != .deny }
}

typealias ApprovalHandler = @Sendable (ApprovalRequest) async -> ApprovalDecision

struct ApprovalRecord: Codable, Equatable, Sendable {
    var agent: AgentID
    var title: String
    var detail: String?
    var rule: String
    /// Nil while waiting.
    var decision: ApprovalDecision?

    /// "Allowed once: Run ls", and the same line for the other answers.
    var summary: String {
        switch decision {
        case .allowOnce: "Allowed once: \(title)"
        case .allowInThread: "Allowed in this thread: \(title)"
        case .allowAlways: "Always allowed: \(title)"
        case .allowEverything: "Allowed everything in this thread: \(title)"
        case .deny: "Denied: \(title)"
        case nil: "No answer: \(title)"
        }
    }
}

enum ApprovalRule {
    static let shellTools = ["Bash"]

    /// `Bash(<program>:*)` for shell commands, the tool name for everything else.
    static func make(tool: String, input: [String: Any]) -> String {
        guard shellTools.contains(tool) else { return tool }
        guard let command = nonemptyString(input["command"]),
              let program = DeniedCommand.programs(in: command, allowed: []).first else {
            return tool
        }
        return "Bash(\(program):*)"
    }

    /// Every program a shell command runs, or nil when it can't be judged by its programs alone.
    /// Command substitution and a redirection that writes a file can run or write anything.
    /// `2>&1` and the other discards to `/dev/null` don't, and neither does a `$name` reference.
    static func shellPrograms(_ command: String) -> [String]? {
        let judged = ShellCommand.maskingHarmlessRedirections(command)
        guard !["$(", "`", ">", "<("].contains(where: judged.contains) else { return nil }
        // A lone `&` runs the next command in the background, which the parser would miss.
        guard judged.replacingOccurrences(of: "&&", with: "").contains("&") == false else { return nil }
        let programs = DeniedCommand.programs(in: judged, allowed: [])
        return programs.isEmpty ? nil : programs
    }

    /// The program in a `Bash(<program>:*)` rule.
    static func program(in rule: String) -> String? {
        guard rule.hasPrefix("Bash("), rule.hasSuffix(":*)") else { return nil }
        let name = String(rule.dropFirst(5).dropLast(3))
        return name.isEmpty ? nil : name
    }

    /// "Web search", "Gmail: send_message", "Run touch".
    static func friendlyName(_ rule: String) -> String {
        if let program = program(in: rule) { return "Run \(program)" }
        switch rule {
        case "WebSearch": return "Web search"
        case "WebFetch": return "Web fetch"
        default: break
        }
        if let (server, tool) = mcpParts(rule) { return "\(server): \(tool)" }
        return rule
    }

    /// `mcp__gmail__send_message` as ("Gmail", "send_message").
    static func mcpParts(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst(5)
        guard let split = rest.range(of: "__") else { return nil }
        let server = rest[..<split.lowerBound]
        let tool = rest[split.upperBound...]
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        let label = server.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return (label.prefix(1).uppercased() + label.dropFirst(), String(tool))
    }
}
