import Foundation
import Synchronization
import Testing
@testable import Desk

@Test func claudeListsTheSameEffortsForEveryModelWithItsOwnDefault() {
    #expect(ModelLists.claudeEfforts.map(\.id) == ["low", "medium", "high", "xhigh", "max"])
    #expect(ModelLists.claudeEfforts.map(\.label) == ["Low", "Medium", "High", "Extra High", "Max"])
    #expect(ModelLists.claudeEfforts.filter(\.isDefault).map(\.id) == ["high"])
    #expect(ModelLists.claude.allSatisfy { $0.efforts.map(\.id) == ModelLists.claudeEfforts.map(\.id) })
    #expect(ModelLists.claude.map { $0.efforts.first(where: \.isDefault)?.id } == ["medium", "high", "medium", "max"])
}

@Test func preferredEffortsOverrideTheCLIsWhereTheModelHasThem() {
    let levels = ["low", "medium", "high", "xhigh", "max"]
    func model(_ id: String, _ efforts: [String] = levels) -> AgentModelOption {
        AgentModelOption(id: id, label: id, isDefault: false, efforts: efforts.map {
            AgentEffortOption(id: $0, label: $0, isDefault: $0 == "medium")
        })
    }
    func defaults(_ options: [AgentModelOption], _ agent: AgentID) -> [String?] {
        ModelLists.preferringEfforts(options, for: agent).map { $0.efforts.first(where: \.isDefault)?.id }
    }
    #expect(defaults([model("gpt-6-astra"), model("gpt-6.1-sol"), model("gpt-5.6-terra"), model("gpt-6-luna")], .codex)
        == ["low", "high", "high", "max"])
    #expect(defaults([model("gpt-6-luna", ["low", "medium", "high", "ultra"]), model("gpt-6-orion")], .codex) == ["ultra", "medium"])
    #expect(defaults([model("grok-4.7"), model("grok-4.5", ["low", "medium", "high"])], .grok) == ["xhigh", "medium"])
    #expect(defaults([model("muse-spark-1-3"), model("muse-spark-1-2", ["low", "medium", "high", "xhigh"])], .muse) == ["max", "medium"])
}

@Test @MainActor func effortsFollowTheNamedModelOrTheDefaultModel() {
    let low = [AgentEffortOption(id: "low", label: "Low", isDefault: true)]
    let high = [AgentEffortOption(id: "high", label: "High", isDefault: true)]
    let catalog = ModelCatalog(options: [
        .claude: ModelLists.claude,
        .codex: [
            AgentModelOption(id: "gpt-a", label: "A", isDefault: false, efforts: low),
            AgentModelOption(id: "gpt-b", label: "B", isDefault: true, efforts: high),
        ],
    ])
    #expect(catalog.efforts(for: .claude, model: nil).map(\.id) == ["low", "medium", "high", "xhigh", "max"])
    #expect(catalog.efforts(for: .claude, model: "claude-haiku-4-5-20251001").map(\.label) == ["Low", "Medium", "High", "Extra High", "Max"])
    #expect(catalog.efforts(for: .claude, model: "missing").isEmpty)
    #expect(catalog.efforts(for: .codex, model: nil).map(\.id) == ["high"])
    #expect(catalog.efforts(for: .codex, model: "gpt-a").map(\.id) == ["low"])
    #expect(catalog.efforts(for: .codex, model: "").map(\.id) == ["high"])
    #expect(catalog.efforts(for: .grok, model: nil).isEmpty)

    let unmarked = ModelCatalog(options: [
        .codex: [AgentModelOption(id: "gpt-a", label: "A", isDefault: false, efforts: low)],
    ])
    #expect(unmarked.efforts(for: .codex, model: nil).map(\.id) == ["low"])
}

@Test func effortArgumentsArePassedPerAgentAndOmittedWhenUnset() {
    let prompt = "User: hi"
    let workspace = URL(filePath: "/tmp/desk-ws")

    let claude = ClaudeCommand.arguments(session: "sess-1", model: "claude-opus-5-5", effort: "max")
    #expect(claude.suffix(6) == ["--model", "claude-opus-5-5", "--effort", "max", "--resume", "sess-1"])
    #expect(ClaudeCommand.arguments(session: nil, effort: nil).contains("--effort") == false)
    #expect(ClaudeCommand.arguments(session: nil, model: "claude-opus-5-5", effort: "").contains("--effort") == false)

    let grok = GrokCommand.arguments(prompt: prompt, session: nil, workspace: workspace, model: "grok-4.7", effort: "xhigh")
    #expect(grok.suffix(4) == ["--model", "grok-4.7", "--reasoning-effort", "xhigh"])
    let grokResumed = GrokCommand.arguments(prompt: prompt, session: "sess-1", workspace: workspace, model: nil, effort: "low")
    #expect(grokResumed.suffix(4) == ["--reasoning-effort", "low", "--resume", "sess-1"])
    #expect(GrokCommand.arguments(prompt: prompt, session: nil, workspace: workspace).contains("--reasoning-effort") == false)

    let preamble = AgentCommand.roundtablePrompt(for: "Muse") + "\n\n" + prompt
    let muse = MuseCommand.arguments(prompt: prompt, session: nil, workspace: workspace, model: "muse-spark", effort: "high")
    #expect(muse.suffix(5) == ["--model", "muse-spark", "--reasoning-effort", "high", preamble])
    let museResumed = MuseCommand.arguments(prompt: prompt, session: "sess-1", workspace: workspace, effort: "low")
    #expect(museResumed.suffix(5) == ["--reasoning-effort", "low", "--session-id", "sess-1", prompt])
    #expect(MuseCommand.arguments(prompt: prompt, session: nil, workspace: workspace, effort: "").contains("--reasoning-effort") == false)
}

@Test func codexTurnStartCarriesEffortAndOmitsItWhenUnset() throws {
    let set = CodexCommand.turnStartParams(threadID: "thr-1", prompt: "User: hi", model: "gpt-5.5", effort: "high")
    #expect(set["effort"] as? String == "high")
    #expect(set["model"] as? String == "gpt-5.5")
    #expect(CodexCommand.turnStartParams(threadID: "thr-1", prompt: "User: hi", model: nil, effort: nil)["effort"] == nil)
    #expect(CodexCommand.turnStartParams(threadID: "thr-1", prompt: "User: hi", model: "gpt-5.5", effort: "")["effort"] == nil)

    let stdin = AgentStdin()
    var session = CodexAppServerSession(
        stdin: stdin,
        prompt: "User: hi",
        session: nil,
        workspace: URL(filePath: "/tmp/desk-ws"),
        model: "gpt-5.5",
        effort: "xhigh"
    )
    session.sessionStarted()
    _ = try session.events(from: #"{"id":1,"result":{}}"#)
    _ = try session.events(from: #"{"id":2,"result":{"thread":{"id":"thr-1"}}}"#)
    let turn = try #require(jsonObject(from: stdin.writtenLines().last ?? ""))
    #expect(turn["method"] as? String == "turn/start")
    let params = try #require(turn["params"] as? [String: Any])
    #expect(params["effort"] as? String == "xhigh")
    #expect(params["model"] as? String == "gpt-5.5")
}

@Test func grokCacheParsingReadsReasoningEffortsFromATempFile() throws {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "desk-grok-cache-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let json = """
    {
      "models": {
        "grok-4.7": {
          "info": {
            "id": "grok-4.7",
            "reasoning_efforts": [
              {"id": "xhigh", "value": "xhigh", "label": "Extra High", "default": false},
              {"id": "high", "label": "High", "default": true},
              {"id": "high", "label": "High again", "default": false},
              {"id": "low", "default": false},
              {"label": "Nope"}
            ]
          }
        },
        "grok-3": {"info": {"id": "grok-3"}}
      }
    }
    """
    try Data(json.utf8).write(to: file)

    let parsed = ModelLists.parseGrokEfforts(at: file)
    #expect(parsed["grok-4.7"] == [
        AgentEffortOption(id: "xhigh", label: "Extra High", isDefault: false),
        AgentEffortOption(id: "high", label: "High", isDefault: true),
        AgentEffortOption(id: "low", label: "Low", isDefault: false),
    ])
    #expect(parsed["grok-3"] == [])
    #expect(ModelLists.parseGrokEfforts(at: file.appending(path: "missing")) == [:])

    let merged = ModelLists.applyGrokEfforts([
        AgentModelOption(id: "grok-4.7", label: "Grok 4.7", isDefault: true),
        AgentModelOption(id: "grok-3", label: "Grok 3", isDefault: false),
        AgentModelOption(id: "grok-missing", label: "Missing", isDefault: false),
    ], from: file)
    #expect(merged[0].efforts.map(\.id) == ["xhigh", "high", "low"])
    #expect(merged[1].efforts.isEmpty)
    #expect(merged[2].efforts.isEmpty)
}

@Test func museVariantsCapitalizeTiersAndDefaultToHigh() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-muse-efforts-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let json = """
    {"rows":[
      {"model_id":"muse-spark","display_label":"Spark","is_default":true,"visibility":"visible","reasoning_effort_variants":[
        {"tier":"low"},{"tier":"high"},{"tier":"xhigh"},{"tier":"high"},{"tier":42},{"tier":"minimal"}
      ]},
      {"model_id":"muse-plain","display_label":"Plain","visibility":"visible"}
    ]}
    """
    try Data(json.utf8).write(to: directory.appending(path: "catalog.json"))

    let options = ModelLists.parseMuseCatalog(at: directory)
    #expect(options.map(\.id) == ["muse-spark", "muse-plain"])
    #expect(options[0].efforts == [
        AgentEffortOption(id: "low", label: "Low", isDefault: false),
        AgentEffortOption(id: "high", label: "High", isDefault: true),
        AgentEffortOption(id: "xhigh", label: "Extra High", isDefault: false),
        AgentEffortOption(id: "minimal", label: "Minimal", isDefault: false),
    ])
    #expect(options[1].efforts.isEmpty)
}

@Test func codexModelListLinesCarryEachModelsEfforts() throws {
    let line = """
    {"id":2,"result":{"data":[
      {"model":"gpt-5.5","displayName":"GPT-5.5","isDefault":true,"defaultReasoningEffort":"high","supportedReasoningEfforts":[
        {"reasoningEffort":"low"},{"reasoningEffort":"high"},{"reasoningEffort":"high"},{"reasoningEffort":"xhigh"},{"nope":true}
      ]},
      {"id":"gpt-hidden","hidden":true,"supportedReasoningEfforts":[{"reasoningEffort":"max"}]},
      {"model":"gpt-mini","displayName":"Mini","isDefault":false}
    ]}}
    """
    let object = try #require(jsonObject(from: line))
    let result = try #require(object["result"] as? [String: Any])
    let options = ModelLists.parseCodexModelList(result)
    #expect(options.map(\.id) == ["gpt-5.5", "gpt-mini"])
    #expect(options[0].efforts == [
        AgentEffortOption(id: "low", label: "Low", isDefault: false),
        AgentEffortOption(id: "high", label: "High", isDefault: true),
        AgentEffortOption(id: "xhigh", label: "Extra High", isDefault: false),
    ])
    #expect(options[1].efforts.isEmpty)
}

@Test @MainActor func selectedEffortIsStoredAndClearedWhenTheModelDropsIt() throws {
    let name = "desk-effort-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }
    let directory = try makeEffortDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = effortCatalog()

    let model = DeskModel(store: ThreadStore(directory: directory), runner: EffortRunner(), defaults: defaults, catalog: catalog)
    #expect(model.selectedEffort(for: .claude) == nil)
    model.setSelectedModel("big", for: .claude)
    model.setSelectedEffort("low", for: .claude)
    #expect(defaults.string(forKey: "effort.claude") == "low")
    #expect(model.selectedEfforts[.claude] == "low")

    let again = DeskModel(store: ThreadStore(directory: directory), runner: EffortRunner(), defaults: defaults, catalog: catalog)
    #expect(again.selectedEffort(for: .claude) == "low")
    #expect(again.selectedModel(for: .claude) == "big")

    again.setSelectedModel("small", for: .claude)
    #expect(again.selectedEffort(for: .claude) == "low")
    again.setSelectedModel(nil, for: .claude)
    #expect(again.selectedEffort(for: .claude) == "low")
    again.setSelectedModel("tiny", for: .claude)
    #expect(again.selectedEffort(for: .claude) == nil)
    #expect(again.selectedEfforts[.claude] == nil)
    #expect(defaults.string(forKey: "effort.claude") == nil)

    let third = DeskModel(store: ThreadStore(directory: directory), runner: EffortRunner(), defaults: defaults, catalog: catalog)
    #expect(third.selectedModel(for: .claude) == "tiny")
    #expect(third.selectedEffort(for: .claude) == nil)

    third.setSelectedEffort("", for: .claude)
    third.setSelectedEffort("max", for: .claude)
    #expect(third.selectedEffort(for: .claude) == "max")
    third.setSelectedEffort(nil, for: .claude)
    #expect(defaults.string(forKey: "effort.claude") == nil)
}

@Test @MainActor func aReplyAsksForTheChosenEffortOrTheModelsDefault() async throws {
    let directory = try makeEffortDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = "desk-effort-run-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }
    let runner = EffortRunner()
    let model = DeskModel(store: ThreadStore(directory: directory), runner: runner, defaults: defaults, catalog: effortCatalog())
    model.setSelectedModel("big", for: .claude)
    model.setSelectedEffort("high", for: .claude)
    model.newThread()
    model.draft = "hi"
    model.send()
    try await waitUntilEffortIdle(model)

    let supported = try #require(model.selectedThread?.messages.last)
    #expect(supported.effort == "high")
    #expect(supported.model == "big")
    #expect(runner.efforts() == ["high"])

    model.setSelectedEffort("max", for: .claude)
    model.draft = "again"
    model.send()
    try await waitUntilEffortIdle(model)
    #expect(model.selectedThread?.messages.last?.effort == "high")
    #expect(runner.efforts() == ["high", "high"])

    model.setSelectedModel("small", for: .claude)
    model.setSelectedEffort(nil, for: .claude)
    model.draft = "plain"
    model.send()
    try await waitUntilEffortIdle(model)
    #expect(runner.efforts() == ["high", "high", "low"])
}

@MainActor
private func effortCatalog() -> ModelCatalog {
    ModelCatalog(options: [
        .claude: [
            AgentModelOption(id: "big", label: "Big", isDefault: true, efforts: [
                AgentEffortOption(id: "low", label: "Low", isDefault: false),
                AgentEffortOption(id: "high", label: "High", isDefault: true),
            ]),
            AgentModelOption(id: "small", label: "Small", isDefault: false, efforts: [
                AgentEffortOption(id: "low", label: "Low", isDefault: true),
            ]),
            AgentModelOption(id: "tiny", label: "Tiny", isDefault: false, efforts: [
                AgentEffortOption(id: "max", label: "Max", isDefault: true),
            ]),
        ],
    ])
}

private func makeEffortDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-effort-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func waitUntilEffortIdle(_ model: DeskModel) async throws {
    for _ in 0..<200 {
        if !model.isRunning { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the turn to finish")
}

private final class EffortRunner: AgentRunner, Sendable {
    private let recorded = Mutex<[String?]>([])

    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort: String?, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        recorded.withLock { $0.append(effort) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("hello"))
            continuation.finish()
        }
    }

    func efforts() -> [String?] {
        recorded.withLock { $0 }
    }
}

@Test @MainActor func runModelAndEffortComeFromTheSameModel() throws {
    let name = "desk-effort-pair-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let directory = try makeEffortDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = ModelCatalog(options: [
        .codex: [
            AgentModelOption(id: "first", label: "First", isDefault: false, efforts: [
                AgentEffortOption(id: "low", label: "Low", isDefault: false),
                AgentEffortOption(id: "medium", label: "Medium", isDefault: true),
            ]),
            AgentModelOption(id: "second", label: "Second", isDefault: false, efforts: [
                AgentEffortOption(id: "high", label: "High", isDefault: true),
            ]),
        ],
    ])
    let model = DeskModel(store: ThreadStore(directory: directory), runner: EffortRunner(), defaults: defaults, catalog: catalog)

    // No model marked default: the first one runs, with its own default effort.
    #expect(model.modelForRun(for: .codex) == "first")
    #expect(model.effortForRun(for: .codex) == "medium")

    // A saved effort the model no longer lists gives way to the model's default, in the picker too.
    model.setSelectedModel("second", for: .codex)
    defaults.set("ultra", forKey: "effort.codex")
    let reloaded = DeskModel(store: ThreadStore(directory: directory), runner: EffortRunner(), defaults: defaults, catalog: catalog)
    #expect(reloaded.selectedEffort(for: .codex) == "ultra")
    #expect(reloaded.effortForRun(for: .codex) == "high")
    #expect(AgentSettingsPickers(model: reloaded, agent: .codex).effortLabel == "High")
}
