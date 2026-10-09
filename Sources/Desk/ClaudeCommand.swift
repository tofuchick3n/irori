import Foundation

enum ClaudeCommand {
    static let missingSessionMarker = "No conversation found with session ID"

    static var roundtablePrompt: String { AgentCommand.roundtablePrompt(for: "Claude") }

    static func arguments(
        session: String?,
        model: String? = nil,
        effort: String? = nil,
        allowsFileWrites: Bool = true,
        allowedCommands: [String] = ["takibi"],
        allowedRules: [String] = []
    ) -> [String] {
        var args = [
            "-p",
            "--verbose",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--permission-mode", allowsFileWrites ? "acceptEdits" : "default",
            "--permission-prompt-tool", "stdio",
        ]
        let commands = allowedCommands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var rules = commands.map { "Bash(\($0):*)" }
        for rule in allowedRules where !rules.contains(rule) && !rule.isEmpty {
            rules.append(rule)
        }
        for rule in rules {
            args.append(contentsOf: ["--allowedTools", rule])
        }
        args.append(contentsOf: [
            "--append-system-prompt", roundtablePrompt + " " + commandGuidance(commands),
        ])
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        if let effort, !effort.isEmpty {
            args.append(contentsOf: ["--effort", effort])
        }
        if let session, !session.isEmpty {
            args.append(contentsOf: ["--resume", session])
        }
        return args
    }

    static func commandGuidance(_ commands: [String]) -> String {
        guard !commands.isEmpty else { return "Every shell command asks the user first." }
        return "You can run these shell commands without asking: \(commands.joined(separator: ", ")). "
            + "Anything else asks the user first, so use it only when it helps."
    }

    static func initializeRequest() -> String {
        jsonLine(["type": "control_request", "request_id": "init-1", "request": ["subtype": "initialize"]])
    }

    static func userMessage(_ prompt: String, images: [URL] = []) -> (line: String, skipped: [String]) {
        let (content, skipped) = Attachments.claudeContent(prompt: prompt, images: images)
        return (jsonLine(["type": "user", "message": ["role": "user", "content": content]]), skipped)
    }

    /// The reply to a `can_use_tool` request. An allowed tool runs with its input unchanged.
    static func controlResponse(requestID: String, input: [String: Any], allow: Bool) -> String {
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "The user said no."]
        return jsonLine([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": response],
        ])
    }

    static func childPATH(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        AgentCommand.childPATH(home: home)
    }

    static func environment(
        inheriting base: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        AgentCommand.environment(inheriting: base, home: home)
    }

    static func candidatePaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            home.appending(path: ".local/bin/claude", directoryHint: .notDirectory).path(percentEncoded: false),
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    static func resolveBinary(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        AgentCommand.resolve(candidates: candidatePaths(home: home), isExecutable: isExecutable)
    }
}
