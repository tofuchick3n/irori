import Foundation
import Testing
@testable import Desk

@Test func claudeSignInParsesLoggedInAndAuthMethod() {
    #expect(SignInStatus.claude(from: #"{"loggedIn":true,"authMethod":"claude.ai"}"#) == .signedIn("claude.ai"))
    #expect(SignInStatus.claude(from: #"{"loggedIn":true}"#) == .signedIn(nil))
    #expect(SignInStatus.claude(from: #"{"loggedIn":true,"authMethod":"  "}"#) == .signedIn(nil))
    #expect(SignInStatus.claude(from: #"{"loggedIn":false,"authMethod":"claude.ai"}"#) == .signedOut)
    #expect(SignInStatus.claude(from: "not json") == .signedOut)
    #expect(SignInStatus.claude(from: "warning\n{\"loggedIn\":true,\"authMethod\":\"api\"}\n") == .signedIn("api"))
    let pretty = """
    {
      "loggedIn": true,
      "authMethod": "claude.ai"
    }
    """
    #expect(SignInStatus.claude(from: pretty) == .signedIn("claude.ai"))
}

@Test func codexSignInRequiresExitZeroAndALoggedInLine() {
    #expect(SignInStatus.codex(stdout: "Logged in using ChatGPT\nmore\n", exitCode: 0) == .signedIn("ChatGPT"))
    #expect(SignInStatus.codex(stdout: "  Logged in  \n", exitCode: 0) == .signedIn(nil))
    #expect(SignInStatus.codex(stdout: "Logged in using ChatGPT\n", exitCode: 1) == .signedOut)
    #expect(SignInStatus.codex(stdout: "Not logged in\n", exitCode: 0) == .signedOut)
    // Codex prints its status on stderr.

}

@Test func grokSignInReadsTheFirstLine() {
    #expect(SignInStatus.grok(from: "You are logged in with ada@x.ai\n* grok-4\n") == .signedIn("ada@x.ai"))
    #expect(SignInStatus.grok(from: "logged in\nwith later\n") == .signedIn(nil))
    #expect(SignInStatus.grok(from: "You are logged in with   \n") == .signedIn(nil))
    #expect(SignInStatus.grok(from: "nope\nlogged in with ada\n") == .signedOut)
}

@Test func museAuthPathRespectsOverrides() {
    let home = URL(filePath: "/Users/example")
    #expect(MuseAuth.file(home: home, environment: [:]) == "/Users/example/.config/muse/auth.json")
    #expect(MuseAuth.file(home: home, environment: ["XDG_CONFIG_HOME": "/custom/config"]) == "/custom/config/muse/auth.json")
    #expect(MuseAuth.file(home: home, environment: ["XDG_CONFIG_HOME": "/custom/config/"]) == "/custom/config/muse/auth.json")
    #expect(MuseAuth.file(home: home, environment: ["XDG_CONFIG_HOME": "~/cfg"]) == "/Users/example/cfg/muse/auth.json")
    #expect(MuseAuth.file(home: home, environment: ["XDG_CONFIG_HOME": "  "]) == "/Users/example/.config/muse/auth.json")
    #expect(MuseAuth.file(home: home, environment: [
        "MUSE_AUTH_PATH": "/opt/muse/auth.json",
        "XDG_CONFIG_HOME": "/custom",
    ]) == "/opt/muse/auth.json")
    #expect(MuseAuth.file(home: home, environment: ["MUSE_AUTH_PATH": "~/Library/muse/auth.json"]) ==
        "/Users/example/Library/muse/auth.json")
    #expect(MuseAuth.file(home: home, environment: ["MUSE_AUTH_PATH": " \n", "XDG_CONFIG_HOME": "/custom"]) ==
        "/custom/muse/auth.json")
}

@Test func terminalCommandQuotesTheBinaryPath() {
    let claude = URL(filePath: "/opt/homebrew/bin/claude")
    #expect(TerminalScript.shellCommand(executable: claude, arguments: SignInCommand.loginArguments(for: .claude)) ==
        "'/opt/homebrew/bin/claude' auth login")
    #expect(TerminalScript.shellCommand(
        executable: URL(filePath: "/opt/homebrew/bin/codex"),
        arguments: SignInCommand.loginArguments(for: .codex)
    ) == "'/opt/homebrew/bin/codex' login")
    #expect(TerminalScript.shellCommand(
        executable: URL(filePath: "/opt/homebrew/bin/grok"),
        arguments: SignInCommand.loginArguments(for: .grok)
    ) == "'/opt/homebrew/bin/grok' login")
    #expect(TerminalScript.shellCommand(
        executable: URL(filePath: "/opt/homebrew/bin/muse"),
        arguments: SignInCommand.loginArguments(for: .muse)
    ) == "'/opt/homebrew/bin/muse' login")
    #expect(TerminalScript.shellCommand(executable: URL(filePath: "/Users/me/My Tools/grok"), arguments: ["login"]) ==
        "'/Users/me/My Tools/grok' login")

    let script = TerminalScript.commandFile(executable: claude, arguments: ["auth", "login"])
    #expect(script == "#!/bin/bash\n'/opt/homebrew/bin/claude' auth login\n")

    let quoted = TerminalScript.shellCommand(executable: URL(filePath: "/tmp/a'b"), arguments: ["login"])
    #expect(quoted == "'/tmp/a'\\''b' login")
    #expect(TerminalScript.commandFile(executable: URL(filePath: "/tmp/a'b"), arguments: ["login"]) == "#!/bin/bash\n" + quoted + "\n")
}

@Test func signInCLIReturnsOutputOrNilWhenItCannotFinish() async {
    let echoed = await SignInCLI.run(executable: URL(filePath: "/bin/echo"), arguments: ["Logged in using test"])
    #expect(echoed?.exitCode == 0)
    #expect(echoed?.stdout.contains("Logged in using test") == true)

    let failed = await SignInCLI.run(executable: URL(filePath: "/usr/bin/false"), arguments: [])
    #expect(failed?.exitCode == 1)

    let missing = await SignInCLI.run(
        executable: URL(filePath: "/tmp/desk-no-such-\(UUID().uuidString)"),
        arguments: []
    )
    #expect(missing == nil)

    let timedOut = await SignInCLI.run(
        executable: URL(filePath: "/bin/sleep"),
        arguments: ["30"],
        timeout: .milliseconds(200)
    )
    #expect(timedOut == nil)
}

/// A CLI that leaves a helper running keeps its pipes open after it exits.
@Test func signInCLIFinishesWhenAChildKeepsItsOutputOpen() async {
    let start = ContinuousClock.now
    let output = await SignInCLI.run(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "echo signed-in; sleep 5 &"],
        timeout: .seconds(10)
    )
    #expect(output?.exitCode == 0)
    #expect(output?.stdout.contains("signed-in") == true)
    #expect(ContinuousClock.now - start < .seconds(3))
}

/// The timeout ends the check on time even when the CLI ignores SIGTERM; it's killed after.
@Test func signInCLITimesOutEvenWhenTerminateIsIgnored() async {
    let start = ContinuousClock.now
    let output = await SignInCLI.run(
        executable: URL(filePath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; sleep 5"],
        timeout: .milliseconds(200)
    )
    #expect(output == nil)
    #expect(ContinuousClock.now - start < .seconds(1))
}

@MainActor
@Test func saveKeyRejectsABadKeyAndWritesAPrivateFile() async throws {
    let home = try makeSignInHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = URL(filePath: TakibiPaths.keyDirectory(home: home), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))

    let script = KeyScript()
    let cli = TakibiPaths.candidates(home: home)[0]
    let service = TakibiService(
        home: home,
        runner: { _, arguments in script.run(arguments) },
        isExecutable: { $0 == cli },
        environment: [:]
    )
    #expect(service.hasKeyFile == false)
    #expect(try TakibiKey.validated("  pub.secret \n") == "pub.secret")
    for bad in ["nope", "  ", "pub.", ".secret", "pub.secret.extra", "pub.sec ret"] {
        #expect(throws: TakibiFailure.self) { try service.saveKey(bad) }
    }
    #expect(FileManager.default.fileExists(atPath: TakibiPaths.keyFile(home: home)) == false)
    #expect(script.calls.isEmpty)

    try service.saveKey("  pub.secret \n")
    let keyPath = TakibiPaths.keyFile(home: home)
    #expect(try String(contentsOf: URL(filePath: keyPath), encoding: .utf8) == "pub.secret\n")
    #expect(try signInMode(at: keyPath) == 0o600)
    #expect(try signInMode(at: directory.path(percentEncoded: false)) == 0o700)
    #expect(service.hasKeyFile)

    for _ in 0..<100 where script.calls.isEmpty || service.isRefreshing {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(script.calls.contains(["projects", "--json"]))
}

@MainActor
@Test func hasKeyFileUsesTheEnvironmentOverride() throws {
    let home = try makeSignInHome()
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(TakibiKey.location(home: URL(filePath: "/Users/example"), environment: [:]) == "/Users/example/.takibi/key")
    #expect(TakibiKey.location(home: URL(filePath: "/Users/example"), environment: ["TAKIBI_KEY_FILE": "~/keys/me"]) ==
        "/Users/example/keys/me")
    #expect(TakibiKey.location(home: URL(filePath: "/Users/example"), environment: ["TAKIBI_KEY_FILE": "  "]) ==
        "/Users/example/.takibi/key")

    let custom = home.appending(path: "custom.key")
    try Data("x".utf8).write(to: custom)
    let overridden = TakibiService(
        home: home,
        runner: { _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
        isExecutable: { _ in false },
        environment: ["TAKIBI_KEY_FILE": custom.path(percentEncoded: false)]
    )
    #expect(overridden.hasKeyFile)

    let missingOverride = TakibiService(
        home: home,
        runner: { _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
        isExecutable: { _ in false },
        environment: ["TAKIBI_KEY_FILE": home.appending(path: "missing.key").path(percentEncoded: false)]
    )
    try FileManager.default.createDirectory(
        at: URL(filePath: TakibiPaths.keyDirectory(home: home), directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    try Data("pub.secret\n".utf8).write(to: URL(filePath: TakibiPaths.keyFile(home: home)))
    #expect(missingOverride.hasKeyFile == false)

    let tilde = TakibiService(
        home: home,
        runner: { _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
        isExecutable: { _ in false },
        environment: ["TAKIBI_KEY_FILE": "~/custom.key"]
    )
    #expect(tilde.hasKeyFile)

    try TakibiService(
        home: home,
        runner: { _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
        isExecutable: { _ in false },
        environment: ["TAKIBI_KEY_FILE": custom.path(percentEncoded: false)]
    ).saveKey("pub.secret")
    // A pasted key goes where the takibi CLI reads it: the override, not ~/.takibi/key.
    #expect(try String(contentsOf: custom, encoding: .utf8) == "pub.secret\n")
}

@MainActor
@Test func refreshSignInChecksOnlyActiveAgents() async throws {
    let home = try makeSignInHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "desk-signin-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let probe = SignInProbe()
    probe.claude = SignInOutput(stdout: #"{"loggedIn":true,"authMethod":"claude.ai"}"#, exitCode: 0)
    probe.codex = SignInOutput(stdout: "Logged in using ChatGPT\n", exitCode: 1)
    probe.grok = nil
    let opened = OpenedScripts()
    let model = DeskModel(
        store: ThreadStore(directory: home),
        trash: { _ in },
        defaults: defaults,
        homeDirectory: home,
        takibi: .inactive(home: home),
        environment: [:],
        signInProbe: { executable, arguments in probe.run(executable: executable, arguments: arguments) },
        openTerminal: { opened.append($0) }
    )
    #expect(model.signIn[.claude] == nil)
    await model.refreshSignIn()
    #expect(model.signIn[.claude] == .signedIn("claude.ai"))
    #expect(model.signIn[.codex] == .signedOut)
    #expect(model.signIn[.grok] == .unknown)
    #expect(model.signIn[.muse] == .signedOut)
    #expect(Set(probe.calls.map(\.arguments)) == [["auth", "status"], ["login", "status"], ["models"]])
    #expect(probe.calls.allSatisfy { $0.path == "/usr/bin/true" })

    model.setEnabled(false, for: .claude)
    model.setEnabled(false, for: .grok)
    let auth = home.appending(path: ".config/muse/auth.json")
    try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: auth)
    probe.reset()
    probe.codex = SignInOutput(stdout: "Logged in using ChatGPT\nnext\n", exitCode: 0)
    await model.refreshSignIn()
    #expect(model.signIn[.claude] == .signedIn("claude.ai"))
    #expect(model.signIn[.grok] == .unknown)
    #expect(model.signIn[.codex] == .signedIn("ChatGPT"))
    #expect(model.signIn[.muse] == .signedIn(nil))
    #expect(probe.calls.map(\.arguments) == [["login", "status"]])

    model.openSignIn(for: .claude)
    #expect(opened.values == [TerminalScript.commandFile(
        executable: URL(filePath: "/usr/bin/true"),
        arguments: ["auth", "login"]
    )])

    let hidden = DeskModel(
        store: ThreadStore(directory: home.appending(path: "other")),
        trash: { _ in },
        defaults: defaults,
        homeDirectory: home,
        isExecutable: { _ in false },
        assumeInstalled: false,
        takibi: .inactive(home: home),
        environment: [:],
        openTerminal: { opened.append($0) }
    )
    hidden.openSignIn(for: .muse)
    #expect(opened.values.count == 1)
}

private func makeSignInHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appending(path: "desk-signin-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func signInMode(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let number = try #require(attributes[.posixPermissions] as? NSNumber)
    return number.intValue & 0o777
}

private final class KeyScript: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]] = []

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func run(_ arguments: [String]) -> TakibiCommandOutput {
        lock.lock()
        stored.append(arguments)
        lock.unlock()
        return TakibiCommandOutput(stdout: #"{"projects":[]}"#, stderr: "", exitCode: 0)
    }
}

private final class OpenedScripts: @unchecked Sendable {
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

private final class SignInProbe: @unchecked Sendable {
    struct Call: Equatable {
        var path: String
        var arguments: [String]
    }

    private let lock = NSLock()
    var claude: SignInOutput?
    var codex: SignInOutput?
    var grok: SignInOutput?
    private var stored: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func reset() {
        lock.lock()
        stored = []
        lock.unlock()
    }

    func run(executable: URL, arguments: [String]) -> SignInOutput? {
        lock.lock()
        stored.append(Call(path: executable.path(percentEncoded: false), arguments: arguments))
        let claude = claude
        let codex = codex
        let grok = grok
        lock.unlock()
        if arguments == ["auth", "status"] { return claude }
        if arguments == ["login", "status"] { return codex }
        if arguments == ["models"] { return grok }
        return nil
    }
}

@Test func codexSignInIsReadFromStderr() async {
    let state = await SignInCheck.evaluate(
        agent: .codex,
        binary: URL(filePath: "/usr/bin/true"),
        home: URL(filePath: "/tmp"),
        environment: [:],
        probe: { _, _ in SignInOutput(stdout: "", exitCode: 0, stderr: "Logged in using ChatGPT\n") }
    )
    #expect(state == .signedIn("ChatGPT"))
    #expect(SignInStatus.grok(from: "You are logged in with grok.com.\n") == .signedIn("grok.com"))
}

@MainActor
@Test func savingToTakibiKeepsTheUnsentDraft() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-draft-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-draft-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = DeskModel(store: ThreadStore(directory: directory), runner: EchoAgentRunner(), trash: { _ in }, defaults: defaults)
    model.newThread()
    let threadID = try #require(model.selection)
    let reply = Message(author: .agent(.claude), body: "Plan")
    try ThreadStore(directory: directory).save(Thread(id: threadID, messages: [reply]))
    let reloaded = DeskModel(store: ThreadStore(directory: directory), runner: EchoAgentRunner(), trash: { _ in }, defaults: defaults)
    reloaded.selection = threadID
    reloaded.draft = "half-written thought"

    reloaded.requestTakibiSave(messageID: reply.id, card: "card-42", agent: .claude)

    #expect(reloaded.draft == "half-written thought")
    #expect(reloaded.selectedThread?.messages.contains { $0.body.contains("Takibi card card-42") } == true)
}

@MainActor
@Test func aPastedAgentKeyBecomesThatAgentsKeyFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-agentkey-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-agentkey-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = DeskModel(
        store: ThreadStore(directory: directory.appending(path: "threads", directoryHint: .isDirectory)),
        runner: EchoAgentRunner(),
        trash: { _ in },
        defaults: defaults,
        supportDirectory: directory
    )

    #expect(throws: TakibiFailure.self) { try model.saveAgentKey("not a key", for: .grok) }
    #expect(model.keyFile(for: .grok) == nil)

    try model.saveAgentKey("  pub123.secret456\n", for: .grok)
    let file = model.agentKeyURL(for: .grok)
    #expect(model.keyFile(for: .grok) == file.path(percentEncoded: false))
    #expect(try String(contentsOf: file, encoding: .utf8) == "pub123.secret456\n")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    model.removeAgentKey(for: .grok)
    #expect(model.keyFile(for: .grok) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
}

@Test func grokSaysNotLoggedInMeansSignedOut() {
    #expect(SignInStatus.grok(from: "Not logged in. Run grok login.\n") == .signedOut)
    #expect(SignInStatus.grok(from: "You are logged in with grok.com.\n") == .signedIn("grok.com"))
}

@MainActor
@Test func aPastedMainKeyGoesWhereTakibiReadsIt() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "desk-keypath-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let override = home.appending(path: "keys/prod.key", directoryHint: .notDirectory)
    let service = TakibiService(
        home: home,
        runner: { _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
        isExecutable: { _ in false },
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        environment: ["TAKIBI_KEY_FILE": override.path(percentEncoded: false)]
    )
    try service.saveKey("pub.secret")
    #expect(try String(contentsOf: override, encoding: .utf8) == "pub.secret\n")
    #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".takibi/key").path(percentEncoded: false)))
    #expect(service.hasKeyFile)
}
