import Foundation

enum Turn {
    static let automaticTitleLength = 40

    /// `@claude`, `@codex`, `@grok`, `@muse`, and `@all`, case-insensitive and word-bounded.
    /// `@all` expands to `all` (active agents, in that order). Duplicates collapse, keeping the first occurrence.
    static func mentionedAgents(in text: String, all: [AgentID] = Array(AgentID.allCases)) -> [AgentID] {
        var result: [AgentID] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@", isBoundary(text, before: index) {
                let tokenStart = text.index(after: index)
                var tokenEnd = tokenStart
                while tokenEnd < text.endIndex, isWord(text[tokenEnd]) {
                    tokenEnd = text.index(after: tokenEnd)
                }
                let token = text[tokenStart..<tokenEnd].lowercased()
                let agents: [AgentID]
                if token == "all" {
                    agents = all
                } else if let agent = AgentID(rawValue: token) {
                    agents = [agent]
                } else {
                    agents = []
                }
                for agent in agents where !result.contains(agent) {
                    result.append(agent)
                }
                index = tokenEnd
                continue
            }
            index = text.index(after: index)
        }
        return result
    }

    /// Agents who should answer `text`. No mention repeats the recipients of the
    /// previous user message. The first message in a thread goes to Claude.
    /// With no mention anywhere yet, `fallback` (the user's default agent) answers.
    static func recipients(for text: String, earlierUserTexts: [String], fallback: AgentID = .claude, all: [AgentID] = Array(AgentID.allCases)) -> [AgentID] {
        let direct = mentionedAgents(in: text, all: all)
        if !direct.isEmpty {
            return direct
        }
        var resolved: [AgentID] = [fallback]
        for earlier in earlierUserTexts {
            let mentioned = mentionedAgents(in: earlier, all: all)
            if !mentioned.isEmpty {
                resolved = mentioned
            }
        }
        return resolved
    }

    static func prompt(messages: [Message], seenThrough cursor: Int?) -> String {
        let start = (cursor ?? -1) + 1
        guard start < messages.count else { return "" }
        return messages[start...].map(transcriptLine).joined(separator: "\n")
    }

    static func lastUserLine(in prompt: String) -> String {
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lastUserLines: [String] = []
        var inUser = false
        for line in lines {
            if let role = role(of: line) {
                if role == "User" {
                    inUser = true
                    lastUserLines = [content(of: line, role: role)]
                } else {
                    inUser = false
                }
            } else if inUser {
                lastUserLines.append(line)
            }
        }
        return lastUserLines.last ?? ""
    }

    static func title(for firstUserMessage: String) -> String {
        let singleLine = firstUserMessage
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.isEmpty {
            return Thread.untitled
        }
        return String(singleLine.prefix(automaticTitleLength))
    }

    private static func transcriptLine(_ message: Message) -> String {
        let speaker: String
        switch message.author {
        case .user:
            speaker = "User"
        case .agent(let agent):
            speaker = agent.displayName
        case .notice:
            speaker = "Notice"
        }
        let lines = message.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return "\(speaker):" }
        let attached = Attachments.promptLine(message.attachments).map { [$0] } ?? []
        return (["\(speaker): \(first)"] + lines.dropFirst() + attached).joined(separator: "\n")
    }

    private static let roles = ["User", "Claude", "Codex", "Grok", "Muse", "Notice"]

    private static func role(of line: String) -> String? {
        roles.first { line.hasPrefix($0 + ":") }
    }

    private static func content(of line: String, role: String) -> String {
        var rest = line.dropFirst(role.count + 1)
        if rest.first == " " {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isBoundary(_ text: String, before index: String.Index) -> Bool {
        index == text.startIndex || !isWord(text[text.index(before: index)])
    }
}
