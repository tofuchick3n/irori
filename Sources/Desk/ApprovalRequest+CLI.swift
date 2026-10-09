import Foundation

extension ApprovalRequest {
    /// A Claude `can_use_tool` control request.
    static func claude(id: String, tool: String, input: [String: Any]) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            tool: tool,
            title: claudeTitle(tool: tool, input: input),
            detail: nonemptyString(input["command"]) ?? shortJSON(input),
            rule: ApprovalRule.make(tool: tool, input: input)
        )
    }

    /// A Codex `…/requestApproval` server request. Nil when the method isn't an approval.
    static func codex(method: String, id: String, params: [String: Any]) -> ApprovalRequest? {
        guard method.hasSuffix("/requestApproval") else { return nil }
        let reason = nonemptyString(params["reason"])
        if let command = nonemptyString(params["command"]).map(WorkStep.unwrappedShell) {
            return ApprovalRequest(
                id: id,
                tool: "Bash",
                title: "Run \(clipped(command))",
                detail: command,
                rule: ApprovalRule.make(tool: "Bash", input: ["command": command])
            )
        }
        if method.contains("fileChange") {
            return ApprovalRequest(id: id, tool: "Edit", title: reason ?? "Edit files", detail: nil, rule: "Edit")
        }
        return ApprovalRequest(id: id, tool: method, title: reason ?? method, detail: nil, rule: method)
    }

    private static func claudeTitle(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            if let command = nonemptyString(input["command"]) { return "Run \(clipped(command))" }
        case "WebSearch":
            if let query = nonemptyString(input["query"]) { return "Search the web for “\(query)”" }
        case "WebFetch":
            if let url = nonemptyString(input["url"]) { return "Fetch \(url)" }
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            if let path = nonemptyString(input["file_path"]) ?? nonemptyString(input["notebook_path"]) {
                let name = (path as NSString).lastPathComponent
                return "\(tool == "Write" ? "Write" : "Edit") \(name)"
            }
        default:
            break
        }
        if let (server, name) = ApprovalRule.mcpParts(tool) { return "Use \(server): \(name)" }
        return "Use \(tool)"
    }

    private static func clipped(_ command: String) -> String {
        let line = command.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? command
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    private static func shortJSON(_ input: [String: Any]) -> String? {
        guard !input.isEmpty, JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              var json = String(data: data, encoding: .utf8) else { return nil }
        if json.count > 2000 { json = String(json.prefix(2000)) + "…" }
        return json
    }
}

/// Tool-use ids the person denied in Desk. Written from the approval task, read by the parser.
final class DeniedToolUses: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}
