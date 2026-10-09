import Foundation

struct ToolServer: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var target: String?
    var status: Status

    enum Status: Equatable, Sendable {
        case connected, needsSignIn, failed(String), disabled, configured

        var label: String {
            switch self {
            case .connected: "Connected"
            case .needsSignIn: "Needs sign-in"
            case .failed: "Couldn't connect"
            case .disabled: "Off"
            case .configured: "Configured"
            }
        }
    }
}

struct AgentTools: Equatable, Sendable {
    var servers: [ToolServer] = []
    var skills: [String] = []
    var error: String?
}

struct ToolsFailure: Error, LocalizedError, Equatable, Sendable {
    var message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

enum ToolsCommand {
    static func listArguments(for agent: AgentID) -> [String]? {
        switch agent {
        case .claude: ["mcp", "list"]
        case .codex: ["mcp", "list", "--json"]
        case .grok: ["mcp", "list", "--json"]
        case .muse: nil
        }
    }

    static let museSkillsArguments = ["skills", "list"]

    static func addArguments(for agent: AgentID, name: String, url: URL) -> [String]? {
        let link = url.absoluteString
        switch agent {
        case .claude: return ["mcp", "add", "-s", "user", "--transport", "http", name, link]
        case .codex: return ["mcp", "add", name, "--url", link]
        case .grok: return ["mcp", "add", "-s", "user", name, link]
        case .muse: return nil
        }
    }

    static func removeArguments(for agent: AgentID, name: String) -> [String]? {
        switch agent {
        case .claude: ["mcp", "remove", "-s", "user", name]
        case .codex: ["mcp", "remove", name]
        case .grok: ["mcp", "remove", name]
        case .muse: nil
        }
    }

    /// Terminal runs this to let the person sign in; names are quoted for the shell.
    static func signInArguments(for agent: AgentID, name: String) -> [String] {
        let quoted = TerminalScript.shellQuote(name)
        switch agent {
        case .claude: return ["/mcp"]
        case .codex: return ["mcp", "login", quoted]
        case .muse: return ["mcp", "login", quoted]
        case .grok: return ["mcp", "doctor", quoted]
        }
    }

    /// A name that can't be mistaken for a flag or split by the shell.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first != "-" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    static func isValidURL(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host(percentEncoded: false)?.isEmpty == false
    }

    static func failureText(_ output: SignInOutput?, fallback: String) -> String? {
        guard let output else { return "\(fallback) The command timed out." }
        guard output.exitCode != 0 else { return nil }
        for text in [output.stderr, output.stdout] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }
}

enum ToolsParser {
    /// `name: target - ✔ Connected`. Names may hold spaces and dots, so split on the first ": ".
    static func claude(from text: String) -> [ToolServer] {
        var servers: [ToolServer] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.range(of: ": ") else { continue }
            let name = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = line[colon.upperBound...]
            guard !name.isEmpty, let marker = statusMarker(in: rest) else { continue }
            let target = rest[..<marker.lowerBound].trimmingCharacters(in: .whitespaces)
            let status = String(rest[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
            servers.append(ToolServer(name: name, target: target.isEmpty ? nil : target, status: claudeStatus(status)))
        }
        return servers
    }

    static func codex(from text: String) -> [ToolServer] {
        entries(from: text).compactMap { item in
            guard let name = nonemptyString(item["name"]) else { return nil }
            let transport = item["transport"] as? [String: Any]
            let target = nonemptyString(transport?["url"]) ?? nonemptyString(transport?["command"])
            let status: ToolServer.Status
            if item["enabled"] as? Bool == false || nonemptyString(item["disabled_reason"]) != nil {
                status = .disabled
            } else if nonemptyString(item["auth_status"])?.lowercased() == "not_logged_in" {
                status = .needsSignIn
            } else {
                status = .configured
            }
            return ToolServer(name: name, target: target, status: status)
        }
    }

    static func grok(from text: String) -> [ToolServer] {
        entries(from: text).compactMap { item in
            guard let name = nonemptyString(item["name"]) else { return nil }
            let status: ToolServer.Status = item["enabled"] as? Bool == false ? .disabled : .configured
            return ToolServer(name: name, target: nonemptyString(item["url"]), status: status)
        }
    }

    /// Skill names from the NAME column; the header row is skipped.
    static func museSkills(from text: String) -> [String] {
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let name = line.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "NAME" { continue }
            names.append(trimmed)
        }
        return names
    }

    private static let markers = [" - ✔", " - ✘", " - !"]

    private static func statusMarker(in text: Substring) -> Range<Substring.Index>? {
        markers.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
            .map { $0.lowerBound..<text.index($0.lowerBound, offsetBy: 3) }
    }

    private static func claudeStatus(_ text: String) -> ToolServer.Status {
        if text.hasPrefix("✔") { return .connected }
        if text.hasPrefix("!") { return .needsSignIn }
        let detail = text.drop { $0 == "✘" || $0 == " " }
        return .failed(String(detail))
    }

    private static func entries(from text: String) -> [[String: Any]] {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array
    }
}
