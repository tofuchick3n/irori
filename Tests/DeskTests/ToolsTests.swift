import Foundation
import Testing
@testable import Desk

private let claudeList = """
Checking MCP server health…

example: https://example.com/mcp - ✔ Connected
broken: https://x.example.com/mcp - ✘ Failed to connect — HTTP 502: Bad Gateway - retry
claude.ai Gmail: https://mail.example.com/mcp - ! Needs authentication
claude.ai Google Drive: https://drive.example.com/mcp - ✔ Connected
local: npx foo - ✔ Connected
"""

private let codexList = """
[
  {"auth_status":"unsupported","disabled_reason":null,"enabled":true,"name":"docs","startup_timeout_sec":null,"tool_timeout_sec":null,"transport":{"type":"streamable_http","url":"https://example.com/mcp"}},
  {"auth_status":"not_logged_in","disabled_reason":null,"enabled":true,"name":"mail","startup_timeout_sec":null,"tool_timeout_sec":null,"transport":{"type":"streamable_http","url":"https://mail.example.com/mcp"}},
  {"auth_status":"unsupported","disabled_reason":"user","enabled":false,"name":"off","startup_timeout_sec":null,"tool_timeout_sec":null,"transport":{"type":"stdio","command":"npx","args":["foo"]}}
]
"""

private let grokList = """
[{"enabled":true,"name":"docs","scope":"user","url":"https://example.com/mcp"},{"enabled":false,"name":"old","scope":"user","url":"https://old.example.com/mcp"}]
"""

private let museSkills = "NAME\tSCOPE\tACTIVATION\tDESCRIPTION\tPATH\nplanner\tuser\tauto\tPlans work\t/x/planner\ntakibi-use\tuser\tauto\tTakibi\t/x/takibi-use\n"

@Test func claudeListParsesNamesTargetsAndStatus() {
    let servers = ToolsParser.claude(from: claudeList)
    #expect(servers.map(\.name) == ["example", "broken", "claude.ai Gmail", "claude.ai Google Drive", "local"])
    #expect(servers[0] == ToolServer(name: "example", target: "https://example.com/mcp", status: .connected))
    #expect(servers[1].status == .failed("Failed to connect — HTTP 502: Bad Gateway - retry"))
    #expect(servers[1].target == "https://x.example.com/mcp")
    #expect(servers[2].status == .needsSignIn)
    #expect(servers[4].target == "npx foo")
    #expect(ToolsParser.claude(from: "").isEmpty)
}

@Test func codexAndGrokListsMapStatus() {
    let codex = ToolsParser.codex(from: codexList)
    #expect(codex == [
        ToolServer(name: "docs", target: "https://example.com/mcp", status: .configured),
        ToolServer(name: "mail", target: "https://mail.example.com/mcp", status: .needsSignIn),
        ToolServer(name: "off", target: "npx", status: .disabled),
    ])
    let grok = ToolsParser.grok(from: grokList)
    #expect(grok.map(\.status) == [.configured, .disabled])
    #expect(grok[0].target == "https://example.com/mcp")
    #expect(ToolsParser.codex(from: "nope").isEmpty)
    #expect(ToolsParser.museSkills(from: museSkills) == ["planner", "takibi-use"])
}

@Test func statusLabelsAreFriendly() {
    #expect(ToolServer.Status.connected.label == "Connected")
    #expect(ToolServer.Status.needsSignIn.label == "Needs sign-in")
    #expect(ToolServer.Status.failed("x").label == "Couldn't connect")
    #expect(ToolServer.Status.disabled.label == "Off")
    #expect(ToolServer.Status.configured.label == "Configured")
}

@Test func addAndRemoveArgumentsPerCLI() throws {
    let url = try #require(URL(string: "https://example.com/mcp"))
    #expect(ToolsCommand.addArguments(for: .claude, name: "docs", url: url) == ["mcp", "add", "-s", "user", "--transport", "http", "docs", "https://example.com/mcp"])
    #expect(ToolsCommand.addArguments(for: .codex, name: "docs", url: url) == ["mcp", "add", "docs", "--url", "https://example.com/mcp"])
    #expect(ToolsCommand.addArguments(for: .grok, name: "docs", url: url) == ["mcp", "add", "-s", "user", "docs", "https://example.com/mcp"])
    #expect(ToolsCommand.addArguments(for: .muse, name: "docs", url: url) == nil)
    #expect(ToolsCommand.removeArguments(for: .claude, name: "docs") == ["mcp", "remove", "-s", "user", "docs"])
    #expect(ToolsCommand.removeArguments(for: .codex, name: "docs") == ["mcp", "remove", "docs"])
    #expect(ToolsCommand.removeArguments(for: .grok, name: "docs") == ["mcp", "remove", "docs"])
    #expect(ToolsCommand.signInArguments(for: .codex, name: "my docs") == ["mcp", "login", "'my docs'"])
    #expect(ToolsCommand.signInArguments(for: .grok, name: "docs") == ["mcp", "doctor", "'docs'"])
    #expect(ToolsCommand.isValidName("docs.v2"))
    #expect(!ToolsCommand.isValidName("-s"))
    #expect(!ToolsCommand.isValidName("a b"))
    #expect(ToolsCommand.isValidURL(url))
    #expect(!ToolsCommand.isValidURL(URL(string: "ftp://example.com")))
    #expect(!ToolsCommand.isValidURL(URL(string: "file:///etc/passwd")))
}

@Test func museSettingsRoundTripKeepsUnknownKeysAndHeaders() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "desk-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = MuseSettings.file(home: home, environment: [:])
    #expect(file.path(percentEncoded: false) == home.appending(path: ".config/muse/settings.json").path(percentEncoded: false))
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = """
    {"theme":"dark","nested":{"a":[1,2,3]},"mcpServers":{"secure":{"mode":"always","url":"https://secure.example.com/mcp","headers":{"Authorization":"Bearer sample"}},"local":{"mode":"off","command":"npx"}}}
    """
    try Data(original.utf8).write(to: file)

    let before = try MuseSettings.servers(at: file)
    #expect(before == [
        ToolServer(name: "local", target: "npx", status: .disabled),
        ToolServer(name: "secure", target: "https://secure.example.com/mcp", status: .configured),
    ])
    try MuseSettings.add(name: "docs", url: try #require(URL(string: "https://example.com/mcp")), to: file)
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["theme"] as? String == "dark")
    #expect((object["nested"] as? [String: Any])?["a"] as? [Int] == [1, 2, 3])
    var servers = try #require(object["mcpServers"] as? [String: Any])
    #expect(servers.keys.sorted() == ["docs", "local", "secure"])
    #expect(servers["docs"] as? [String: String] == ["mode": "optional", "url": "https://example.com/mcp"])
    let headers = (servers["secure"] as? [String: Any])?["headers"] as? [String: String]
    #expect(headers == ["Authorization": "Bearer sample"])
    #expect(throws: ToolsFailure.self) {
        try MuseSettings.add(name: "docs", url: URL(filePath: "/x"), to: file)
    }

    try MuseSettings.remove(name: "docs", from: file)
    object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    servers = try #require(object["mcpServers"] as? [String: Any])
    #expect(servers.keys.sorted() == ["local", "secure"])
    #expect(object["theme"] as? String == "dark")
}

@Test func museSettingsCreatesMissingFileAndRespectsXDGAndRefusesBadJSON() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "desk-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let config = home.appending(path: "xdg").path(percentEncoded: false)
    let file = MuseSettings.file(home: home, environment: ["XDG_CONFIG_HOME": config])
    #expect(file.path(percentEncoded: false) == config + "/muse/settings.json")
    #expect(try MuseSettings.servers(at: file).isEmpty)
    try MuseSettings.add(name: "docs", url: try #require(URL(string: "https://example.com/mcp")), to: file)
    #expect(try MuseSettings.servers(at: file).map(\.name) == ["docs"])

    try Data("{ not json".utf8).write(to: file)
    #expect(throws: ToolsFailure.self) {
        try MuseSettings.add(name: "x", url: URL(filePath: "/x"), to: file)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
}

private final class ToolsRunnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func run(_ arguments: [String]) -> SignInOutput? {
        lock.lock()
        stored.append(arguments)
        lock.unlock()
        switch arguments.first {
        case "mcp" where arguments.dropFirst().first == "list":
            return SignInOutput(stdout: arguments.contains("--json") ? grokList : claudeList, exitCode: 0)
        case "mcp" where arguments.contains("codex-fail"):
            return SignInOutput(stdout: "", exitCode: 1, stderr: "already exists\n")
        case "skills":
            return SignInOutput(stdout: museSkills, exitCode: 0)
        default:
            return SignInOutput(stdout: "", exitCode: 0)
        }
    }
}

@MainActor
private func toolsModel(home: URL, defaults: UserDefaults, runner: @escaping @Sendable (URL, [String]) async -> SignInOutput?, opened: (@Sendable (String) -> Void)? = nil) -> DeskModel {
    DeskModel(
        store: ThreadStore(directory: home),
        trash: { _ in },
        defaults: defaults,
        homeDirectory: home,
        takibi: .inactive(home: home),
        environment: [:],
        openTerminal: opened ?? { _ in },
        toolsRunner: runner
    )
}

@MainActor
@Test func refreshToolsListsServersAndSkillsForEveryActiveAgent() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "desk-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "desk-tools-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for folder in [".claude/skills/alpha", ".claude/skills/beta", ".codex/skills/gamma"] {
        try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
    }
    try Data().write(to: home.appending(path: ".claude/skills/not-a-folder.txt"))
    let log = ToolsRunnerLog()
    let model = toolsModel(home: home, defaults: defaults) { _, arguments in log.run(arguments) }
    model.setEnabled(false, for: .grok)
    await model.refreshTools()

    #expect(model.tools[.claude]?.skills == ["alpha", "beta"])
    #expect(model.tools[.claude]?.servers.count == 5)
    #expect(model.tools[.codex]?.skills == ["gamma"])
    #expect(model.tools[.codex]?.servers.map(\.name) == ["docs", "old"])
    #expect(model.tools[.muse]?.skills == ["planner", "takibi-use"])
    #expect(model.tools[.muse]?.servers == [])
    #expect(model.tools[.grok] == nil)
    #expect(Set(log.calls) == [["mcp", "list"], ["mcp", "list", "--json"], ["skills", "list"]])
}

@MainActor
@Test func refreshToolsReportsAFailedListPerAgent() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "desk-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "desk-tools-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = toolsModel(home: home, defaults: defaults) { _, arguments in
        arguments.contains("--json") ? SignInOutput(stdout: "", exitCode: 2, stderr: "boom") : nil
    }
    await model.refreshTools()
    #expect(model.tools[.codex]?.error == "boom")
    #expect(model.tools[.claude]?.error == "Couldn't list servers. The command timed out.")
}

@MainActor
@Test func addServerReportsEachAgentAndWritesMuseSettings() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "desk-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "desk-tools-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = ToolsRunnerLog()
    let model = toolsModel(home: home, defaults: defaults) { _, arguments in
        arguments.first == "mcp" && arguments.dropFirst().first == "add" && arguments.contains("--url")
            ? SignInOutput(stdout: "", exitCode: 1, stderr: "already exists\n")
            : log.run(arguments)
    }
    let url = try #require(URL(string: "https://example.com/mcp"))
    let results = await model.addServer(name: "docs", url: url, to: [.claude, .codex, .grok, .muse])
    #expect(results[.claude] == .some(nil))
    #expect(results[.codex] == .some("already exists"))
    #expect(results[.grok] == .some(nil))
    #expect(results[.muse] == .some(nil))
    #expect(log.calls.contains(["mcp", "add", "-s", "user", "--transport", "http", "docs", "https://example.com/mcp"]))
    #expect(log.calls.contains(["mcp", "add", "-s", "user", "docs", "https://example.com/mcp"]))
    #expect(model.tools[.muse]?.servers.map(\.name) == ["docs"])

    let bad = await model.addServer(name: "--x", url: url, to: [.claude])
    #expect(bad[.claude] != .some(nil))
    let ftp = await model.addServer(name: "ok", url: try #require(URL(string: "ftp://example.com")), to: [.codex])
    #expect(ftp[.codex] != .some(nil))
}

@MainActor
@Test func removeServerRunsTheCLIOrEditsMuseAndSignInOpensTerminal() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "desk-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "desk-tools-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = ToolsRunnerLog()
    let scripts = ScriptLog()
    let model = toolsModel(home: home, defaults: defaults, runner: { _, arguments in
        arguments == ["mcp", "remove", "codex-fail"] ? SignInOutput(stdout: "", exitCode: 1, stderr: "no such server") : log.run(arguments)
    }, opened: { scripts.append($0) })

    try await model.removeServer("docs", from: .claude)
    #expect(log.calls.contains(["mcp", "remove", "-s", "user", "docs"]))
    await #expect(throws: ToolsFailure("no such server")) {
        try await model.removeServer("codex-fail", from: .codex)
    }

    let file = MuseSettings.file(home: home, environment: [:])
    try MuseSettings.add(name: "docs", url: try #require(URL(string: "https://example.com/mcp")), to: file)
    try await model.removeServer("docs", from: .muse)
    #expect(try MuseSettings.servers(at: file).isEmpty)

    model.openToolSignIn(for: .codex, server: "mail")
    #expect(scripts.values == [TerminalScript.commandFile(executable: URL(filePath: "/usr/bin/true"), arguments: ["mcp", "login", "'mail'"])])
}

private final class ScriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}
