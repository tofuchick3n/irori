import Foundation

enum GrokCommand {
    static let missingSessionMarker = "Failed to restore session"

    static func arguments(
        prompt: String,
        session: String?,
        workspace: URL,
        model: String? = nil,
        effort: String? = nil,
        allowsFileWrites: Bool = true
    ) -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "streaming-messages-json",
            "--include-partial-messages",
            "--cwd", workspace.path(percentEncoded: false),
            "--sandbox", allowsFileWrites ? "workspace" : "read-only",
            "--always-approve",
            "--no-subagents",
            "--rules", AgentCommand.roundtablePrompt(for: "Grok"),
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        if let effort, !effort.isEmpty {
            args.append(contentsOf: ["--reasoning-effort", effort])
        }
        if let session, !session.isEmpty {
            args.append(contentsOf: ["--resume", session])
        }
        return args
    }

    static func candidatePaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            home.appending(path: ".local/bin/grok", directoryHint: .notDirectory).path(percentEncoded: false),
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
        ]
    }
}
