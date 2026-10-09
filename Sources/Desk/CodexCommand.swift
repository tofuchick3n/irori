import Foundation

enum CodexCommand {
    static let missingSessionMarker = "no rollout found for thread id"
    static let rejectedRequestMessage = "Interactive requests are disabled in \(Brand.name)."

    static func arguments() -> [String] {
        ["app-server", "--stdio"]
    }

    static func initializeParams(experimentalAPI: Bool = true) -> [String: Any] {
        [
            "clientInfo": [
                "name": Brand.slug,
                "title": Brand.name,
                "version": "0.1.0",
            ],
            "capabilities": [
                "experimentalApi": experimentalAPI,
                "requestAttestation": false,
            ],
        ]
    }

    /// `sandbox` is the kebab-case mode string. Network stays a config override, the same knob the old exec `-c` flag set.
    /// Read-only also drops that override: Codex's read-only sandbox blocks the network, so `takibi` cannot run until writes are allowed again.
    static func threadParams(
        workspace: URL,
        model: String?,
        instructions: String = AgentCommand.roundtablePrompt(for: "Codex"),
        allowsFileWrites: Bool = true
    ) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": workspace.path(percentEncoded: false),
            "approvalPolicy": "on-request",
            "sandbox": allowsFileWrites ? "workspace-write" : "read-only",
            "developerInstructions": instructions,
        ]
        // Codex can hand approvals to its own AI reviewer instead; here the person decides.
        var config: [String: Any] = ["approvals_reviewer": "user"]
        if allowsFileWrites {
            config["sandbox_workspace_write.network_access"] = true
        }
        params["config"] = config
        if let model, !model.isEmpty {
            params["model"] = model
        }
        return params
    }

    static func threadStartParams(
        workspace: URL,
        model: String?,
        instructions: String = AgentCommand.roundtablePrompt(for: "Codex"),
        allowsFileWrites: Bool = true
    ) -> [String: Any] {
        threadParams(workspace: workspace, model: model, instructions: instructions, allowsFileWrites: allowsFileWrites)
    }

    static func threadResumeParams(
        threadID: String,
        workspace: URL,
        model: String?,
        instructions: String = AgentCommand.roundtablePrompt(for: "Codex"),
        allowsFileWrites: Bool = true
    ) -> [String: Any] {
        var params = threadParams(workspace: workspace, model: model, instructions: instructions, allowsFileWrites: allowsFileWrites)
        params["threadId"] = threadID
        params["excludeTurns"] = true
        return params
    }

    static func turnStartParams(threadID: String, prompt: String, model: String?, effort: String? = nil, images: [URL] = []) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [[
                "type": "text",
                "text": prompt,
                "text_elements": [Any](),
            ]] + images.map { ["type": "localImage", "path": $0.path(percentEncoded: false)] },
            "summary": "concise",
        ]
        if let model, !model.isEmpty {
            params["model"] = model
        }
        if let effort, !effort.isEmpty {
            params["effort"] = effort
        }
        return params
    }

    static func request(method: String, id: Int, params: [String: Any]) -> String {
        jsonLine(["id": id, "method": method, "params": params])
    }

    static func notification(_ method: String) -> String {
        jsonLine(["method": method])
    }

    static func rejectedRequest(id: Any) -> String {
        jsonLine([
            "id": id,
            "error": [
                "code": -32601,
                "message": rejectedRequestMessage,
            ],
        ])
    }

    /// `cancel` is for Stop; the person's own No is `decline`.
    static func approvalResponse(id: Any, decision: ApprovalDecision, cancelled: Bool = false) -> String {
        let answer = cancelled ? "cancel" : decision.allows ? "accept" : "decline"
        return jsonLine(["id": id, "result": ["decision": answer]])
    }

    static func candidatePaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            "/opt/homebrew/bin/codex",
            home.appending(path: ".local/bin/codex", directoryHint: .notDirectory).path(percentEncoded: false),
            "/usr/local/bin/codex",
        ]
    }
}
