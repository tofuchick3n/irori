import Foundation

struct AgentEffortOption: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var isDefault: Bool
}

struct AgentModelOption: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var isDefault: Bool
    var efforts: [AgentEffortOption] = []
}

@MainActor
@Observable
final class ModelCatalog {
    private(set) var options: [AgentID: [AgentModelOption]]
    /// Agents Desk should ask for models. Inactive agents are left empty.
    var activeAgents: [AgentID] = Array(AgentID.allCases)
    /// Resolved CLI paths. Empty means search the usual places.
    var binaries: [AgentID: URL] = [:]
    /// Agents the last `refresh()` actually queried, in `AgentID` order.
    private(set) var refreshedAgents: [AgentID] = []

    init(options: [AgentID: [AgentModelOption]]? = nil) {
        self.options = options ?? [.claude: ModelLists.claude]
    }

    func refresh() async {
        let active = activeAgents
        let binaries = binaries
        var refreshed: [AgentID] = []
        for agent in AgentID.allCases where active.contains(agent) {
            refreshed.append(agent)
        }
        refreshedAgents = refreshed
        let codexBinary = binaries[.codex]
        let grokBinary = binaries[.grok]
        async let codex = Self.load(refreshed.contains(.codex)) { await ModelLists.codexOptions(executable: codexBinary) }
        async let grok = Self.load(refreshed.contains(.grok)) { await ModelLists.grokOptions(executable: grokBinary) }
        let claude = refreshed.contains(.claude) ? ModelLists.claude : []
        let muse = refreshed.contains(.muse) ? ModelLists.museOptions() : []
        options = [
            .claude: claude,
            .codex: ModelLists.preferringEfforts(await codex, for: .codex),
            .grok: ModelLists.preferringEfforts(await grok, for: .grok),
            .muse: ModelLists.preferringEfforts(muse, for: .muse),
        ]
    }

    private static func load(
        _ querying: Bool,
        _ body: @Sendable () async -> [AgentModelOption]
    ) async -> [AgentModelOption] {
        guard querying else { return [] }
        return await body()
    }

    func label(for modelID: String, agent: AgentID) -> String {
        if let match = options[agent]?.first(where: { $0.id == modelID }) {
            return match.label
        }
        return agent == .muse ? ModelLists.museLabel(id: modelID, display: nil) : ModelLists.tidy(modelID)
    }

    /// The agent's default model, or the first listed model when none is marked.
    func defaultModel(for agent: AgentID) -> AgentModelOption? {
        let models = options[agent] ?? []
        return models.first { $0.isDefault } ?? models.first
    }

    /// `model` nil uses `defaultModel(for:)`.
    func efforts(for agent: AgentID, model: String?) -> [AgentEffortOption] {
        let match: AgentModelOption?
        if let model, !model.isEmpty {
            match = options[agent]?.first { $0.id == model }
        } else {
            match = defaultModel(for: agent)
        }
        return match?.efforts ?? []
    }
}

enum ModelLists {
    static let claudeEfforts: [AgentEffortOption] = [
        AgentEffortOption(id: "low", label: "Low", isDefault: false),
        AgentEffortOption(id: "medium", label: "Medium", isDefault: false),
        AgentEffortOption(id: "high", label: "High", isDefault: true),
        AgentEffortOption(id: "xhigh", label: "Extra High", isDefault: false),
        AgentEffortOption(id: "max", label: "Max", isDefault: false),
    ]

    static let claude: [AgentModelOption] = preferringEfforts([
        AgentModelOption(id: "claude-opus-5-5", label: "Opus 5.5", isDefault: true, efforts: claudeEfforts),
        AgentModelOption(id: "claude-sonnet-5-5", label: "Sonnet 5.5", isDefault: false, efforts: claudeEfforts),
        AgentModelOption(id: "claude-fable-5-1", label: "Fable 5.1", isDefault: false, efforts: claudeEfforts),
        AgentModelOption(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5", isDefault: false, efforts: claudeEfforts),
    ], for: .claude)

    /// Lowest to highest; an effort this doesn't know sorts last.
    static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    static func effortRank(_ id: String) -> Int {
        effortOrder.firstIndex(of: id) ?? effortOrder.count
    }

    /// irori's own pick of a model's default effort, over the one its CLI marks.
    static func preferredEffort(agent: AgentID, model: AgentModelOption) -> String? {
        let words = Set("\(model.id) \(model.label)".lowercased().split { !$0.isLetter && !$0.isNumber })
        switch agent {
        case .claude:
            if words.contains("opus") { return "medium" }
            if words.contains("sonnet") { return "high" }
            if words.contains("fable") { return "medium" }
            if words.contains("haiku") { return "max" }
            return nil
        case .codex:
            if words.contains("astra") { return "low" }
            if words.contains("sol") || words.contains("terra") { return "high" }
            if words.contains("luna") { return model.efforts.map(\.id).max { effortRank($0) < effortRank($1) } }
            return nil
        case .grok:
            return "xhigh"
        case .muse:
            return "max"
        }
    }

    /// Marks each model's preferred effort as its default; a model that doesn't list it keeps the CLI's.
    static func preferringEfforts(_ options: [AgentModelOption], for agent: AgentID) -> [AgentModelOption] {
        options.map { option in
            guard let preferred = preferredEffort(agent: agent, model: option),
                  option.efforts.contains(where: { $0.id == preferred }) else { return option }
            var copy = option
            copy.efforts = option.efforts.map { AgentEffortOption(id: $0.id, label: $0.label, isDefault: $0.id == preferred) }
            return copy
        }
    }

    static func tidy(_ id: String) -> String {
        var text = id
        if let range = text.range(of: #"-(\d{8})$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let parts = text.split { $0 == "-" || $0 == "_" }.map(String.init)
        guard !parts.isEmpty else { return id }
        var splitAt = parts.count
        while splitAt > 0, !parts[splitAt - 1].isEmpty, parts[splitAt - 1].allSatisfy(\.isNumber) {
            splitAt -= 1
        }
        var words = parts[..<splitAt].map(capitalized)
        let numbers = Array(parts[splitAt...])
        if numbers.count >= 2 {
            words.append(contentsOf: numbers.dropLast(2))
            words.append("\(numbers[numbers.count - 2]).\(numbers[numbers.count - 1])")
        } else {
            words.append(contentsOf: numbers)
        }
        let label = words.joined(separator: " ")
        return label.isEmpty ? id : label
    }

    /// Muse's catalog repeats the raw id as its label; show "Spark 1.3 Contributor" instead.
    static func museLabel(id: String, display: String?) -> String {
        if let display, display != id {
            return display
        }
        let name = id.hasPrefix("muse-") ? String(id.dropFirst("muse-".count)) : id
        return name.split(separator: "-").map { word in
            word.first?.isLetter == true ? word.prefix(1).uppercased() + word.dropFirst() : String(word)
        }.joined(separator: " ")
    }

    static func parseGrokModels(_ text: String) -> [AgentModelOption] {
        var options: [AgentModelOption] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
            let isStar: Bool
            if trimmed.hasPrefix("* ") {
                isStar = true
            } else if trimmed.hasPrefix("- ") {
                isStar = false
            } else {
                continue
            }
            var body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            var isDefault = false
            if isStar, body.hasSuffix("(default)") {
                isDefault = true
                body = String(body.dropLast("(default)".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !body.isEmpty, !options.contains(where: { $0.id == body }) else { continue }
            options.append(AgentModelOption(id: body, label: tidy(body), isDefault: isDefault))
        }
        return options
    }

    static func parseMuseCatalog(at directory: URL) -> [AgentModelOption] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let files = urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var options: [AgentModelOption] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["rows"] as? [Any] else {
                continue
            }
            for row in rows {
                guard let row = row as? [String: Any] else { continue }
                if let visibility = row["visibility"], !(visibility is NSNull), (visibility as? String) != "visible" {
                    continue
                }
                guard let id = nonemptyString(row["model_id"]), !options.contains(where: { $0.id == id }) else { continue }
                options.append(AgentModelOption(
                    id: id,
                    label: museLabel(id: id, display: nonemptyString(row["display_label"])),
                    isDefault: jsonBool(row["is_default"]),
                    efforts: museEfforts(from: row)
                ))
            }
        }
        return options
    }

    static func parseCodexModelList(_ result: [String: Any]) -> [AgentModelOption] {
        let rows = result["data"] as? [Any] ?? []
        var options: [AgentModelOption] = []
        for row in rows {
            guard let row = row as? [String: Any], !jsonBool(row["hidden"]) else { continue }
            guard let id = nonemptyString(row["id"]) ?? nonemptyString(row["model"]) else { continue }
            guard !options.contains(where: { $0.id == id }) else { continue }
            options.append(AgentModelOption(
                id: id,
                label: nonemptyString(row["displayName"]) ?? tidy(id),
                isDefault: jsonBool(row["isDefault"]),
                efforts: codexEfforts(from: row)
            ))
        }
        return options
    }

    static func museOptions(directory: URL? = nil) -> [AgentModelOption] {
        parseMuseCatalog(at: directory ?? MuseCommand.modelCatalogDirectory())
    }

    static func grokOptions(executable: URL? = nil) async -> [AgentModelOption] {
        await withTimeout(seconds: 20) { await loadGrok(executable: executable) } ?? []
    }

    static func codexOptions(executable: URL? = nil) async -> [AgentModelOption] {
        await withTimeout(seconds: 20) { await loadCodex(executable: executable) } ?? []
    }

    static func grokModelsCacheURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".grok/models_cache.json", directoryHint: .notDirectory)
    }

    static func parseGrokEfforts(at file: URL) -> [String: [AgentEffortOption]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        guard let models = object["models"] as? [String: Any] else { return [:] }
        var result: [String: [AgentEffortOption]] = [:]
        for (key, value) in models {
            guard let entry = value as? [String: Any] else { continue }
            let info = entry["info"] as? [String: Any] ?? [:]
            let id = nonemptyString(info["id"]) ?? nonemptyString(info["model"]) ?? key
            let raw = (info["reasoning_efforts"] as? [Any]) ?? (entry["reasoning_efforts"] as? [Any]) ?? []
            var efforts: [AgentEffortOption] = []
            for item in raw {
                guard let item = item as? [String: Any] else { continue }
                guard let effortID = nonemptyString(item["id"]) ?? nonemptyString(item["value"]) else { continue }
                guard !efforts.contains(where: { $0.id == effortID }) else { continue }
                efforts.append(AgentEffortOption(
                    id: effortID,
                    label: nonemptyString(item["label"]) ?? effortLabel(for: effortID),
                    isDefault: jsonBool(item["default"])
                ))
            }
            result[id] = efforts
        }
        return result
    }

    static func applyGrokEfforts(_ options: [AgentModelOption], from cache: URL) -> [AgentModelOption] {
        let efforts = parseGrokEfforts(at: cache)
        guard !efforts.isEmpty else { return options }
        return options.map { option in
            guard let found = efforts[option.id], !found.isEmpty else { return option }
            var copy = option
            copy.efforts = found
            return copy
        }
    }

    private static func codexEfforts(from row: [String: Any]) -> [AgentEffortOption] {
        let defaultID = nonemptyString(row["defaultReasoningEffort"])
        guard let raw = row["supportedReasoningEfforts"] as? [Any] else { return [] }
        var efforts: [AgentEffortOption] = []
        for item in raw {
            guard let item = item as? [String: Any], let id = nonemptyString(item["reasoningEffort"]) else { continue }
            guard !efforts.contains(where: { $0.id == id }) else { continue }
            efforts.append(AgentEffortOption(id: id, label: effortLabel(for: id), isDefault: id == defaultID))
        }
        return efforts
    }

    private static func museEfforts(from row: [String: Any]) -> [AgentEffortOption] {
        guard let raw = row["reasoning_effort_variants"] as? [Any] else { return [] }
        var efforts: [AgentEffortOption] = []
        for item in raw {
            guard let item = item as? [String: Any], let tier = nonemptyString(item["tier"]) else { continue }
            guard !efforts.contains(where: { $0.id == tier }) else { continue }
            efforts.append(AgentEffortOption(id: tier, label: effortLabel(for: tier), isDefault: tier == "high"))
        }
        return efforts
    }

    private static func effortLabel(for id: String) -> String {
        if id.caseInsensitiveCompare("xhigh") == .orderedSame {
            return "Extra High"
        }
        return capitalized(id)
    }

    private static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    private static func loadGrok(executable: URL?) async -> [AgentModelOption] {
        let workspace = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            let text = try await capture(
                label: "grok",
                executable: executable,
                candidates: GrokCommand.candidatePaths(),
                arguments: ["models"],
                workspace: workspace,
                succeedsOnCleanExit: true
            ) { OutputLines() }
            return applyGrokEfforts(parseGrokModels(text), from: grokModelsCacheURL())
        } catch {
            return []
        }
    }

    private static func loadCodex(executable: URL?) async -> [AgentModelOption] {
        let workspace = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let box = CodexModelListBox()
        let stdin = AgentStdin()
        let stream = AgentProcess(
            label: "codex",
            executable: executable,
            candidates: CodexCommand.candidatePaths(),
            arguments: CodexCommand.arguments(),
            environment: AgentCommand.environment(),
            workspace: workspace,
            notFound: "codex was not found.",
            stdin: stdin
        ).run {
            CodexModelListSession(stdin: stdin, box: box)
        }
        do {
            for try await _ in stream {}
        } catch {
            return []
        }
        return box.read()
    }

    private static func capture<Parser: AgentLineParser>(
        label: String,
        executable: URL?,
        candidates: [String],
        arguments: [String],
        workspace: URL,
        succeedsOnCleanExit: Bool,
        parser: @escaping @Sendable () -> Parser
    ) async throws -> String {
        let stream = AgentProcess(
            label: label,
            executable: executable,
            candidates: candidates,
            arguments: arguments,
            environment: AgentCommand.environment(),
            workspace: workspace,
            notFound: "\(label) was not found.",
            succeedsOnCleanExit: succeedsOnCleanExit
        ).run(parser)
        var text = ""
        for try await event in stream {
            if case .text(let chunk) = event {
                text += chunk
                text += "\n"
            }
        }
        return text
    }

    private static func temporaryWorkspace() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "desk-models-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private enum Timed<T: Sendable>: Sendable {
        case value(T)
        case timeout
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: Timed<T>.self) { group in
            group.addTask { .value(await operation()) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            if case .value(let value) = first {
                return value
            }
            return nil
        }
    }
}

private struct OutputLines: AgentLineParser {
    var finishedCleanly: Bool { false }

    mutating func events(from line: String) throws -> [AgentEvent] {
        [.text(line)]
    }
}

private final class CodexModelListBox: @unchecked Sendable {
    private let lock = NSLock()
    private var options: [AgentModelOption] = []

    func store(_ options: [AgentModelOption]) {
        lock.lock()
        self.options = options
        lock.unlock()
    }

    func read() -> [AgentModelOption] {
        lock.lock()
        defer { lock.unlock() }
        return options
    }
}

private struct CodexModelListSession: AgentLineParser {
    var stdin: AgentStdin
    var box: CodexModelListBox
    private var initializeID: Int?
    private var listID: Int?
    private(set) var finishedCleanly = false

    init(stdin: AgentStdin, box: CodexModelListBox) {
        self.stdin = stdin
        self.box = box
    }

    mutating func sessionStarted() {
        initializeID = 1
        stdin.write(CodexCommand.request(
            method: "initialize",
            id: 1,
            params: CodexCommand.initializeParams(experimentalAPI: false)
        ))
    }

    mutating func events(from line: String) throws -> [AgentEvent] {
        guard let object = jsonObject(from: line) else { return [] }
        guard case .number(let value) = jsonID(object["id"]) else { return [] }
        if value == initializeID, listID == nil, object["result"] != nil, !(object["result"] is NSNull) {
            stdin.write(CodexCommand.notification("initialized"))
            listID = 2
            stdin.write(CodexCommand.request(method: "model/list", id: 2, params: [:]))
            return []
        }
        if value == listID {
            if let result = object["result"] as? [String: Any] {
                box.store(ModelLists.parseCodexModelList(result))
            }
            finishedCleanly = true
            stdin.close()
        }
        return []
    }
}
