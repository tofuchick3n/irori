import Foundation

enum AgentCommand {
    static func roundtablePrompt(for name: String) -> String {
        "You are \(name), one of four AI agents (Claude, Codex, Grok, Muse) brainstorming with the user in one shared thread. Each turn you receive the messages since your last reply as a transcript of `Name: text` lines. Reply only as yourself, without a name prefix. Messages from other agents are their own views: build on them, challenge them, or agree. Save any file you make in the current working directory, this thread's folder, where the user sees it beside the thread. Don't publish work elsewhere (hosted pages, artifacts, online docs) unless the user asks. Write to Takibi with the `takibi` CLI only when the user asks you to."
    }

    /// Finder launches do not inherit a shell PATH. The child still needs `takibi`.
    static func childPATH(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var root = home.path(percentEncoded: false)
        if root.count > 1, root.hasSuffix("/") {
            root.removeLast()
        }
        return "\(root)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    }

    static func environment(
        inheriting base: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keyFile: String? = nil
    ) -> [String: String] {
        var env = base
        env["PATH"] = childPATH(home: home)
        if let keyFile {
            let expanded = expandingTilde(keyFile, home: home).trimmingCharacters(in: .whitespacesAndNewlines)
            if !expanded.isEmpty {
                env["TAKIBI_KEY_FILE"] = expanded
            }
        }
        return env
    }

    static func resolve(
        candidates: [String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        candidates.first(where: isExecutable).map { URL(filePath: $0) }
    }

    static func candidatePaths(for agent: AgentID, home: URL) -> [String] {
        switch agent {
        case .claude: ClaudeCommand.candidatePaths(home: home)
        case .codex: CodexCommand.candidatePaths(home: home)
        case .grok: GrokCommand.candidatePaths(home: home)
        case .muse: MuseCommand.candidatePaths(home: home)
        }
    }

    /// `~/…` and `~` expand to `home`. Any other path is returned unchanged.
    static func expandingTilde(_ path: String, home: URL) -> String {
        var root = home.path(percentEncoded: false)
        if root.count > 1, root.hasSuffix("/") {
            root.removeLast()
        }
        if path == "~" {
            return root
        }
        guard path.hasPrefix("~/") else { return path }
        return root + path.dropFirst(1)
    }
}
