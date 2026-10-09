import SwiftUI

enum AgentID: String, CaseIterable, Codable, Sendable {
    case claude, codex, grok, muse

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .muse: "Muse"
        }
    }

    /// Where to get the CLI. Nil while the agent has no public page.
    var installURL: URL? {
        switch self {
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")
        case .codex: URL(string: "https://github.com/openai/codex")
        case .grok, .muse: nil
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt"
        case .muse: "paintpalette"
        }
    }

    var color: Color {
        switch self {
        case .claude: .orange
        case .codex: .blue
        case .grok: .purple
        case .muse: .teal
        }
    }
}
