import Foundation
import Observation

struct TakibiProject: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
}

struct TakibiCommandOutput: Sendable, Equatable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

struct TakibiFailure: Error, LocalizedError, Equatable, Sendable {
    var message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

enum TakibiPaths {
    static func candidates(home: URL) -> [String] {
        [
            "\(root(home))/.local/bin/takibi",
            "/opt/homebrew/bin/takibi",
            "/usr/local/bin/takibi",
        ]
    }

    static func skill(_ agent: AgentID, home: URL) -> String {
        "\(skillsDirectory(agent, home: home))/takibi-use"
    }

    static func skillsDirectory(_ agent: AgentID, home: URL) -> String {
        "\(root(home))/\(skillFolder(agent))/skills"
    }

    static func grokSkillsDirectory(home: URL) -> String {
        "\(root(home))/.grok/skills"
    }

    static func keyDirectory(home: URL) -> String {
        "\(root(home))/.takibi"
    }

    static func keyFile(home: URL) -> String {
        "\(root(home))/.takibi/key"
    }

    private static func skillFolder(_ agent: AgentID) -> String {
        switch agent {
        case .claude: ".claude"
        case .codex: ".codex"
        case .muse: ".agents"
        case .grok: ".grok"
        }
    }

    private static func root(_ home: URL) -> String {
        var path = home.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

enum TakibiStatus {

    /// `{"projects":[{"name","id"}]}` on success. An `error.message` wins over stderr.
    static func projects(stdout: String, stderr: String, exitCode: Int32) -> (projects: [TakibiProject], error: String?) {
        let fallback = failureText(stdout: stdout, stderr: stderr)
        if let object = jsonObject(from: stdout) {
            if let error = object["error"] as? [String: Any] {
                return ([], nonemptyString(error["message"]) ?? fallback)
            }
            if let raw = object["projects"] as? [Any], exitCode == 0 {
                return (parseProjects(raw), nil)
            }
        }
        return ([], fallback)
    }

    static func failureText(stdout: String, stderr: String, fallback: String = "Couldn't list Takibi projects.") -> String {
        if let object = jsonObject(from: stdout),
           let error = object["error"] as? [String: Any],
           let message = nonemptyString(error["message"]) {
            return message
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func parseProjects(_ raw: [Any]) -> [TakibiProject] {
        var projects: [TakibiProject] = []
        for item in raw {
            guard let item = item as? [String: Any],
                  let name = nonemptyString(item["name"]),
                  let id = nonemptyString(item["id"]) else { continue }
            projects.append(TakibiProject(id: id, name: name))
        }
        return projects
    }
}

enum TakibiInstall {
    /// One combined `--install` for Claude, Codex, and Muse, then Grok's `--dir` install.
    static func commands(missing: [AgentID], home: URL) -> [[String]] {
        let needed = Set(missing)
        let flags = [(AgentID.claude, "--claude"), (.codex, "--codex"), (.muse, "--agents")]
            .filter { needed.contains($0.0) }
            .map(\.1)
        var commands: [[String]] = []
        if !flags.isEmpty {
            commands.append(["skill", "--install"] + flags)
        }
        if needed.contains(.grok) {
            commands.append(["skill", "--install", "--dir", TakibiPaths.grokSkillsDirectory(home: home)])
        }
        return commands
    }
}

enum TakibiContext {
    static func line(tags: [String], projects: [TakibiProject]) -> String? {
        var names: [String] = []
        var seen = Set<String>()
        for tag in tags {
            let slug = TagLibrary.slug(tag)
            guard !slug.isEmpty, seen.insert(slug).inserted else { continue }
            guard let project = projects.first(where: { TagLibrary.slug($0.name) == slug }) else { continue }
            names.append(project.name)
        }
        switch names.count {
        case 0:
            return nil
        case 1:
            let name = quote(names[0])
            return "Context: this thread is about the Takibi project \(name). Pass --project \(name) to takibi commands."
        default:
            return "Context: this thread is about the Takibi projects \(list(names)). Pass --project with the right one to takibi commands."
        }
    }

    private static func quote(_ name: String) -> String {
        "\"\(name)\""
    }

    private static func list(_ names: [String]) -> String {
        let quoted = names.map(quote)
        if quoted.count == 2 {
            return "\(quoted[0]) and \(quoted[1])"
        }
        return quoted.dropLast().joined(separator: ", ") + ", and " + quoted[quoted.count - 1]
    }
}

enum TakibiKey {
    /// Writes a pasted API key as the one-line file the takibi CLI reads: folder 0700, file 0600.
    static func write(_ raw: String, to file: URL) throws {
        let trimmed = try validated(raw)
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
            try Data((trimmed + "\n").utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
        } catch {
            throw TakibiFailure("Couldn't save the Takibi key. \(error.localizedDescription)")
        }
    }

    /// Trimmed, and exactly `publicId.secret` with both sides nonempty.
    static func validated(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !trimmed.contains(where: \.isWhitespace) else {
            throw TakibiFailure("A Takibi key looks like publicId.secret.")
        }
        return trimmed
    }
}

enum TakibiCard {
    static func id(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let hash = text.firstIndex(of: "#") {
            text = String(text[..<hash])
        }
        if let query = text.firstIndex(of: "?") {
            text = String(text[..<query])
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }
        // A link's host is not a path component. `https://host/` has no card id.
        if let url = URL(string: text), url.scheme != nil {
            let component = url.path.split(separator: "/").last.map(String.init) ?? ""
            let id = component.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }
        if let slash = text.lastIndex(of: "/") {
            text = String(text[text.index(after: slash)...])
        }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func request(agent: AgentID, message: Message, cardID: String) -> String {
        let whose: String
        if case .agent(let author) = message.author {
            whose = author == agent ? "your" : "\(author.displayName)'s"
        } else {
            whose = "the user's"
        }
        let time = clock(message.createdAt)
        // The agent may not have this reply in its context (it can predate its last turn), so include it.
        let quoted = message.body.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        return "@\(agent.rawValue) Attach \(whose) reply from \(time), quoted below, to Takibi card \(cardID) as a markdown artifact (takibi tasks artifact add \(cardID) --markdown -), with a short title. Reply with the artifact id.\n\n\(quoted)"
    }
}

@MainActor
@Observable
final class TakibiService {
    static let mainKey = "main"

    private(set) var cliPath: URL?
    private(set) var projects: [TakibiProject] = []
    private(set) var projectsError: String?
    private(set) var skillInstalled: [AgentID: Bool] = [:]
    private(set) var isRefreshing = false
    /// Which keys are saved: `mainKey` and agents' raw values. The keys themselves stay out of view state.
    private(set) var savedKeys: Set<String> = []
    private(set) var keysError: String?
    /// `~/.takibi/key`, which the takibi CLI falls back to for any program that runs it.
    private(set) var sharedKeyFileExists = false

    var hasKey: Bool {
        savedKeys.contains(Self.mainKey)
    }

    func hasOwnKey(_ agent: AgentID) -> Bool {
        savedKeys.contains(agent.rawValue)
    }

    @ObservationIgnored private var keys: [String: String]?
    @ObservationIgnored private var loading: Task<[String: String], Error>?
    @ObservationIgnored private var writing: Task<Void, Error>?
    private let home: URL
    private let keyStore: any TakibiKeyStore
    private let keyFolder: URL
    private let runner: @Sendable (URL, [String], String?) async throws -> TakibiCommandOutput
    private let isExecutable: @Sendable (String) -> Bool
    private let fileExists: @Sendable (String) -> Bool

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keyStore: any TakibiKeyStore = KeychainKeyStore(),
        keyFolder: URL = FileManager.default.temporaryDirectory,
        runner: @escaping @Sendable (URL, [String], String?) async throws -> TakibiCommandOutput = TakibiCLI.run,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.home = home
        self.keyStore = keyStore
        self.keyFolder = keyFolder
        self.runner = runner
        self.isExecutable = isExecutable
        self.fileExists = fileExists
    }

    /// Tests use this so a `DeskModel` never launches the real `takibi` binary or reads the Keychain.
    static func inactive(home: URL) -> TakibiService {
        TakibiService(
            home: home,
            keyStore: MemoryKeyStore(),
            runner: { _, _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
            isExecutable: { _ in false },
            fileExists: { _ in false }
        )
    }

    /// Trims, requires `publicId.secret`, and saves it in the Keychain under `name`. Then refreshes.
    func saveKey(_ raw: String, for name: String = mainKey) async throws {
        let key = try TakibiKey.validated(raw)
        try await update { $0[name] = key }
        await refresh()
    }

    func removeKey(for name: String) async throws {
        try await update { $0[name] = nil }
    }

    /// Adds keys found outside the Keychain. A key already saved under the same name wins.
    func importKeys(_ found: [String: String]) async throws {
        try await update { $0.merge(found) { saved, _ in saved } }
    }

    /// Writes the key one run uses: the agent's own, else the main key. With no agent, the main key,
    /// else any agent's. Nil when there is none. The caller removes the file when the run ends.
    func keyFile(for agent: AgentID?) async -> TakibiKeyFile? {
        guard let keys = try? await loadedKeys() else { return nil }
        let key = agent.flatMap { keys[$0.rawValue] }
            ?? keys[Self.mainKey]
            ?? (agent == nil ? AgentID.allCases.lazy.compactMap { keys[$0.rawValue] }.first : nil)
        guard let key else { return nil }
        do {
            return try TakibiKeyFile.write(key, in: keyFolder)
        } catch {
            keysError = error.localizedDescription
            return nil
        }
    }

    func deleteSharedKeyFile() throws {
        do {
            try FileManager.default.removeItem(atPath: TakibiPaths.keyFile(home: home))
        } catch CocoaError.fileNoSuchFile {
        } catch {
            throw TakibiFailure("Couldn't delete ~/.takibi/key. \(error.localizedDescription)")
        }
        sharedKeyFileExists = false
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await reload()
    }

    func installSkill() async throws {
        guard let executable = cliPath else {
            throw TakibiFailure("takibi isn't installed.")
        }
        let missing = AgentID.allCases.filter { skillInstalled[$0] != true }
        var failure: String?
        for arguments in TakibiInstall.commands(missing: missing, home: home) {
            do {
                let result = try await runner(executable, arguments, nil)
                if result.exitCode != 0, failure == nil {
                    failure = TakibiStatus.failureText(
                        stdout: result.stdout,
                        stderr: result.stderr,
                        fallback: "takibi skill --install failed."
                    )
                }
            } catch {
                if failure == nil {
                    failure = error.localizedDescription
                }
            }
        }
        await refresh()
        if let failure {
            throw TakibiFailure(failure)
        }
    }

    /// Reads the Keychain once; later calls, and calls made while it reads, share what it returned.
    private func loadedKeys() async throws -> [String: String] {
        if let keys {
            return keys
        }
        if let loading {
            return try await loading.value
        }
        let keyStore = keyStore
        let task = Task.detached { try keyStore.load() }
        loading = task
        defer { loading = nil }
        do {
            let loaded = try await task.value
            if keys == nil {
                keys = loaded
                savedKeys = Set(loaded.keys)
            }
            keysError = nil
            return keys ?? loaded
        } catch {
            keysError = error.localizedDescription
            throw error
        }
    }

    /// One change at a time, each starting from what the one before saved.
    private func update(_ change: @escaping @MainActor (inout [String: String]) -> Void) async throws {
        let previous = writing
        let task = Task { @MainActor in
            _ = await previous?.result
            var updated = try await self.loadedKeys()
            change(&updated)
            guard updated != self.keys else { return }
            let keyStore = self.keyStore
            try await Task.detached { [updated] in try keyStore.save(updated) }.value
            self.keys = updated
            self.savedKeys = Set(updated.keys)
            self.keysError = nil
        }
        writing = task
        try await task.value
    }

    private func reload() async {
        var installed: [AgentID: Bool] = [:]
        for agent in AgentID.allCases {
            installed[agent] = fileExists(TakibiPaths.skill(agent, home: home))
        }
        skillInstalled = installed
        sharedKeyFileExists = fileExists(TakibiPaths.keyFile(home: home))
        _ = try? await loadedKeys()
        cliPath = AgentCommand.resolve(candidates: TakibiPaths.candidates(home: home), isExecutable: isExecutable)
        guard let executable = cliPath else {
            projects = []
            projectsError = nil
            return
        }

        let keyFile = await keyFile(for: nil)
        defer { keyFile?.remove() }
        do {
            let result = try await runner(executable, ["projects", "--json"], keyFile?.path)
            let parsed = TakibiStatus.projects(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
            projects = parsed.projects
            projectsError = parsed.error
        } catch {
            projects = []
            projectsError = error.localizedDescription
        }
    }
}

enum TakibiCLI {
    static func run(executable: URL, arguments: [String], keyFile: String?) async throws -> TakibiCommandOutput {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "desk-takibi-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stream = AgentProcess(
            label: "takibi",
            executable: executable,
            candidates: [],
            arguments: arguments,
            environment: AgentCommand.environment(keyFile: keyFile),
            workspace: workspace,
            notFound: "takibi was not found in ~/.local/bin, /opt/homebrew/bin, or /usr/local/bin.",
            succeedsOnCleanExit: true
        ).run { TakibiLineParser() }
        var lines: [String] = []
        do {
            for try await event in stream {
                if case .text(let line) = event {
                    lines.append(line)
                }
            }
            return TakibiCommandOutput(stdout: lines.joined(separator: "\n"), stderr: "", exitCode: 0)
        } catch let error as AgentRunError {
            return TakibiCommandOutput(stdout: lines.joined(separator: "\n"), stderr: error.message, exitCode: 1)
        }
    }
}

private struct TakibiLineParser: AgentLineParser {
    var finishedCleanly: Bool { false }

    mutating func events(from line: String) throws -> [AgentEvent] {
        [.text(line)]
    }
}
