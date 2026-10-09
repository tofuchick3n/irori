import Foundation

/// One thing an agent did during a reply: thinking, a command, a file it read or wrote, or another tool.
struct WorkStep: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case thinking, command, fileWrite, fileRead, tool, approval }
    enum State: String, Codable, Sendable { case running, done, failed }

    var id: String
    var kind: Kind
    var title: String
    var detail: String?
    var state: State = .running
    var startedAt: Date = .now
    var endedAt: Date?

    /// The title in the present tense while the step runs: "Running takibi …" rather than "Ran takibi …".
    var liveTitle: String {
        guard state == .running else { return title }
        for (past, present) in [("Ran ", "Running "), ("Wrote ", "Writing "), ("Read ", "Reading "), ("Used ", "Using "), ("Edited ", "Editing ")]
        where title.hasPrefix(past) {
            return present + title.dropFirst(past.count)
        }
        return title
    }

    static func thinking(id: String) -> WorkStep {
        WorkStep(id: id, kind: .thinking, title: "Thinking")
    }

    /// An approval the person already answered, shown in the reply's work log.
    static func approval(_ record: ApprovalRecord, id: UUID, at date: Date) -> WorkStep {
        WorkStep(id: id.uuidString, kind: .approval, title: record.summary, detail: record.detail, state: .done, startedAt: date)
    }

    static func command(id: String, _ command: String) -> WorkStep {
        let trimmed = unwrappedShell(command.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return WorkStep(id: id, kind: .command, title: "Ran a command") }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        let short = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        return WorkStep(id: id, kind: .command, title: "Ran \(short)", detail: trimmed)
    }

    static func fileWrite(id: String, path: String) -> WorkStep {
        WorkStep(id: id, kind: .fileWrite, title: "Wrote \(fileName(path))", detail: path)
    }

    /// A tool call by name, as Claude, Grok, Codex, and Muse report them.
    static func tool(id: String, name: String, input: [String: Any]?) -> WorkStep {
        let path = ["file_path", "path", "target_file", "file"].lazy.compactMap { nonemptyString(input?[$0]) }.first
        switch name {
        case "Bash", "bash", "run_terminal_command", "shell":
            return command(id: id, nonemptyString(input?["command"]) ?? "")
        case "Write", "Edit", "MultiEdit", "NotebookEdit", "write_file", "edit_file", "apply_patch",
             "search_replace", "str_replace", "str_replace_editor", "create_file", "write", "edit":
            guard let path else { return WorkStep(id: id, kind: .fileWrite, title: "Edited files") }
            return fileWrite(id: id, path: path)
        case "Read", "read_file", "view_file":
            guard let path else { return WorkStep(id: id, kind: .fileRead, title: "Read a file") }
            if fileName(path) == "SKILL.md" {
                let skill = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return WorkStep(id: id, kind: .fileRead, title: "Read the \(skill) skill", detail: path)
            }
            return WorkStep(id: id, kind: .fileRead, title: "Read \(fileName(path))", detail: path)
        case "read_skill", "Skill":
            let skill = nonemptyString(input?["name"]) ?? nonemptyString(input?["skill"])
            return WorkStep(id: id, kind: .fileRead, title: skill.map { "Read the \($0) skill" } ?? "Read a skill")
        default:
            return WorkStep(id: id, kind: .tool, title: "Used \(name)")
        }
    }

    /// Codex reports commands as `/bin/zsh -lc '<command>'`; show only the command.
    static func unwrappedShell(_ command: String) -> String {
        let shells = ["/bin/zsh", "/bin/bash", "/bin/sh", "zsh", "bash", "sh"]
        for shell in shells {
            for flag in [" -lc ", " -c "] where command.hasPrefix(shell + flag) {
                var inner = String(command.dropFirst(shell.count + flag.count)).trimmingCharacters(in: .whitespaces)
                if inner.count >= 2, let first = inner.first, first == "'" || first == "\"", inner.last == first {
                    inner = String(inner.dropFirst().dropLast())
                    if first == "\"" {
                        inner = inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                    }
                }
                return inner
            }
        }
        return command
    }

    private static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// The programs in a refused shell command that the user hasn't allowed.
enum DeniedCommand {
    static func programs(in command: String, allowed: [String]) -> [String] {
        var programs: [String] = []
        for words in commandWords(in: command) {
            guard let program = invocation(in: words)?.program,
                  !allowed.contains(program),
                  !programs.contains(program) else { continue }
            programs.append(program)
        }
        return programs
    }

    static func commandWords(in command: String) -> [[Substring]] {
        var separated = command
        for separator in ["||", "&&", "|", ";", "\n"] {
            separated = separated.replacingOccurrences(of: separator, with: "\u{0}")
        }
        return separated.split(separator: "\u{0}").compactMap { part in
            let words = Array(part.split(whereSeparator: { $0 == " " || $0 == "\t" }))
            return words.isEmpty ? nil : words
        }
    }

    /// The program and the words after it. Assignments in front (`D=/tmp`) are not the program.
    static func invocation(in words: [Substring]) -> (program: String, arguments: [Substring])? {
        guard let index = words.firstIndex(where: { !isAssignment($0) }) else { return nil }
        var program = (String(words[index]) as NSString).lastPathComponent
        program = program.trimmingCharacters(in: CharacterSet(charactersIn: "(){}\"'`"))
        guard !program.isEmpty else { return nil }
        return (program, Array(words[words.index(after: index)...]))
    }

    static func isAssignment(_ word: Substring) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// Sizes and dates of every file in a thread's folder, to tell which ones a turn created or changed.
struct FolderSnapshot: Equatable {
    private var entries: [String: [Double]] = [:]

    init(_ folder: URL) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(prefix) else { continue }
            entries[String(path.dropFirst(prefix.count))] = [
                Double(values.fileSize ?? 0),
                values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
            ]
        }
    }

    /// Paths created or changed since `earlier`, sorted.
    func changes(since earlier: FolderSnapshot) -> [String] {
        entries.filter { earlier.entries[$0.key] != $0.value }.keys.sorted()
    }
}
