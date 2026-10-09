import Foundation

/// Shell programs that don't change anything. `find` and `git` are included only for the forms that read.
enum ReadOnlyShell {
    static let programs: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "egrep", "rg", "wc", "pwd", "cd",
        "echo", "printf", "file", "stat", "du", "df", "which", "type", "whoami", "date",
        "tree", "sort", "uniq", "cut", "tr", "basename", "dirname", "realpath", "jq",
        "diff", "cmp",
    ]

    /// Every invocation of `program` in `command` only reads.
    /// Harmless redirections are ignored here too, so `ls>/dev/null` is still `ls`.
    static func allows(_ program: String, in command: String) -> Bool {
        let judged = ShellCommand.maskingHarmlessRedirections(command)
        let segments = DeniedCommand.commandWords(in: judged).filter { DeniedCommand.invocation(in: $0)?.program == program }
        guard !segments.isEmpty else { return false }
        // For programs whose flags decide whether they write, the shell can turn `$FLAG`, `-d\elete`, or
        // `GIT_EXTERNAL_DIFF=…` into something the flag checks never saw.
        let opaque = flagSensitive.contains(program) && segments.contains { words in
            words.first.map(DeniedCommand.isAssignment) == true || words.contains { $0.contains("$") || $0.contains("\\") }
        }
        guard !opaque else { return false }
        let runs = segments.compactMap(DeniedCommand.invocation)
        if programs.contains(program) { return runs.allSatisfy { !writesOrRuns(program, $0.arguments) } }
        if program == "find" { return runs.allSatisfy { findReads($0.arguments) } }
        if program == "git" { return runs.allSatisfy { gitReads($0.arguments) } }
        return false
    }

    /// The command only reads, and can be judged from its programs.
    static func isEntirelyReadOnly(_ command: String) -> Bool {
        guard let names = ApprovalRule.shellPrograms(command) else { return false }
        return names.allSatisfy { allows($0, in: command) }
    }

    private static let flagSensitive: Set<String> = ["find", "git", "sort", "tree", "rg", "file"]

    /// Flags that turn an otherwise read-only program into one that writes a file or runs a command.
    private static let unsafeFlags: [String: [String]] = [
        "sort": ["-o", "--output", "--compress-program"],
        "file": ["-C", "--compile"],
        "tree": ["-o"],
        "rg": ["--pre"],
    ]

    private static func writesOrRuns(_ program: String, _ arguments: [Substring]) -> Bool {
        guard let flags = unsafeFlags[program] else { return false }
        return arguments.map(unquoted).contains { word in
            flags.contains { word == $0 || word.hasPrefix($0 + "=") || ($0.count == 2 && word.hasPrefix($0)) }
        }
    }

    /// `find` reads unless it deletes, runs a command, or writes a listing to a file.
    private static func findReads(_ arguments: [Substring]) -> Bool {
        arguments.allSatisfy { word in
            let token = unquoted(word)
            if token == "-delete" || token == "-exec" || token == "-execdir" || token == "-ok" || token == "-okdir" || token == "-fls" {
                return false
            }
            return !token.hasPrefix("-fprint")
        }
    }

    /// `status`, `log`, `diff`, `show`, `rev-parse`, `ls-files`, and `blame` read.
    /// `branch` reads when it only lists. `remote` reads for the listing, including `-v`.
    private static func gitReads(_ arguments: [Substring]) -> Bool {
        let args = arguments.map(unquoted)
        guard let subcommand = args.first else { return true }
        let rest = Array(args.dropFirst())
        switch subcommand {
        case "status", "rev-parse", "ls-files", "blame":
            return true
        case "diff", "show", "log":
            return !rest.contains { $0 == "--output" || $0.hasPrefix("--output=") || $0 == "--ext-diff" }
        case "branch":
            return branchListsOnly(rest)
        case "remote":
            return rest.isEmpty || rest.allSatisfy { $0 == "-v" || $0 == "--verbose" }
        default:
            return false
        }
    }

    private static let branchMutators: Set<String> = [
        "-d", "-D", "--delete",
        "-m", "-M", "--move",
        "-c", "-C", "--copy",
        "-f", "--force",
        "-u", "--set-upstream-to", "--unset-upstream", "--set-upstream",
        "--edit-description",
        "-t", "--track", "--no-track",
    ]

    /// The next word is a commit or a format, not a branch name to create.
    private static let branchValueFlags: Set<String> = [
        "--contains", "--no-contains",
        "--merged", "--no-merged",
        "--points-at",
        "--format", "--sort",
    ]

    private static let branchMutatorLetters = "dDmMcCfFut"

    private static func branchListsOnly(_ args: [String]) -> Bool {
        var expectValue = false
        for arg in args {
            if expectValue {
                expectValue = false
                continue
            }
            if arg == "--" || !arg.hasPrefix("-") { return false }
            if let equals = arg.firstIndex(of: "=") {
                if branchMutators.contains(String(arg[..<equals])) { return false }
                continue
            }
            if branchMutators.contains(arg) { return false }
            if arg.count > 2, !arg.hasPrefix("--"), arg.dropFirst().contains(where: { branchMutatorLetters.contains($0) }) {
                return false
            }
            if branchValueFlags.contains(arg) { expectValue = true }
        }
        return !expectValue
    }

    private static func unquoted(_ word: Substring) -> String {
        let text = String(word)
        guard text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }
}
