import Foundation

enum Mention {
    struct Query: Equatable, Sendable {
        /// Character offsets of the `@partial` token. `end` is the caret.
        var start: Int
        var end: Int
        var letters: String
    }

    enum Choice: String, CaseIterable, Equatable, Sendable {
        case claude, codex, grok, muse, all

        var title: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            case .grok: "Grok"
            case .muse: "Muse"
            case .all: "All"
            }
        }

        var symbolName: String {
            switch self {
            case .all:
                "person.3"
            case .claude, .codex, .grok, .muse:
                AgentID(rawValue: rawValue)?.symbolName ?? "person.3"
            }
        }

        var insertion: String { "@\(rawValue) " }
    }

    /// The `@` query the caret is inside, when the caret sits at the end of `@` plus letters and that `@` starts a word.
    static func query(in text: String, caret: Int) -> Query? {
        guard caret > 0, caret <= text.count else { return nil }
        let caretIndex = text.index(text.startIndex, offsetBy: caret)
        if caretIndex < text.endIndex, text[caretIndex].isLetter {
            return nil
        }
        var index = caretIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous].isLetter {
                index = previous
                continue
            }
            break
        }
        guard index > text.startIndex else { return nil }
        let at = text.index(before: index)
        guard text[at] == "@", isBoundary(text, before: at) else { return nil }
        return Query(
            start: text.distance(from: text.startIndex, to: at),
            end: caret,
            letters: String(text[index..<caretIndex])
        )
    }

    static func query(in text: String, caret: String.Index) -> Query? {
        guard caret >= text.startIndex, caret <= text.endIndex else { return nil }
        return query(in: text, caret: text.distance(from: text.startIndex, to: caret))
    }

    /// Matching agents in `among` order. "All" is included only when two or more agents are active.
    static func choices(matching letters: String, among agents: [AgentID]) -> [Choice] {
        let prefix = letters.lowercased()
        var result: [Choice] = []
        for agent in agents {
            guard let choice = Choice(rawValue: agent.rawValue), choice != .all, choice.rawValue.hasPrefix(prefix) else { continue }
            result.append(choice)
        }
        if agents.count >= 2, Choice.all.rawValue.hasPrefix(prefix) {
            result.append(.all)
        }
        return result
    }

    /// Replaces the partial token with `@name ` and returns the caret just after that space.
    static func apply(_ choice: Choice, to text: String, query: Query) -> (text: String, caret: Int) {
        let start = text.index(text.startIndex, offsetBy: query.start)
        let end = text.index(text.startIndex, offsetBy: query.end)
        let updated = text.replacingCharacters(in: start..<end, with: choice.insertion)
        return (updated, query.start + choice.insertion.count)
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isBoundary(_ text: String, before index: String.Index) -> Bool {
        index == text.startIndex || !isWord(text[text.index(before: index)])
    }
}
