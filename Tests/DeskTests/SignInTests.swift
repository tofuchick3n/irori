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
@Test func saveKeyRejectsABadKeyAndKeepsAGoodOneInTheKeyStore() async throws {
    let home = try makeSignInHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = MemoryKeyStore()
    let script = KeyScript()
    let cli = TakibiPaths.candidates(home: home)[0]
    let service = TakibiService(
        home: home,
        keyStore: store,
        keyFolder: home,
        runner: { _, arguments, keyFile in
            script.run(arguments, key: keyFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) })
        },
        isExecutable: { $0 == cli }
    )
    #expect(service.hasKey == false)
    #expect(try TakibiKey.validated("  pub.secret \n") == "pub.secret")
    for bad in ["nope", "  ", "pub.", ".secret", "pub.secret.extra", "pub.sec ret"] {
        await #expect(throws: TakibiFailure.self) { try await service.saveKey(bad) }
    }
    #expect(try store.load().isEmpty)
    #expect(script.calls.isEmpty)

    try await service.saveKey("  pub.secret \n")
    #expect(try store.load() == ["main": "pub.secret"])
    #expect(service.hasKey)
    #expect(FileManager.default.fileExists(atPath: TakibiPaths.keyFile(home: home)) == false)
    // `takibi projects` got the key in a file that is gone once the command finished.
    #expect(script.calls.contains(["projects", "--json"]))
    #expect(script.keys.last == "pub.secret\n")
    let left = try FileManager.default.contentsOfDirectory(atPath: home.path(percentEncoded: false))
    #expect(!left.contains { $0.hasPrefix(TakibiKeyFile.prefix) })
}

@MainActor
@Test func theSharedKeyFileCanBeDeleted() async throws {
    let home = try makeSignInHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = URL(filePath: TakibiPaths.keyDirectory(home: home), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("pub.secret\n".utf8).write(to: URL(filePath: TakibiPaths.keyFile(home: home)))
    let service = TakibiService(
        home: home,
        keyStore: MemoryKeyStore(),
        runner: { _, _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
        isExecutable: { _ in false }
    )
    await service.refresh()
    #expect(service.sharedKeyFileExists)
    try service.deleteSharedKeyFile()
    #expect(service.sharedKeyFileExists == false)
    #expect(FileManager.default.fileExists(atPath: TakibiPaths.keyFile(home: home)) == false)
    try service.deleteSharedKeyFile()
}

@Test func aKeyFileIsPrivateAndRemovable() throws {
    let parent = try makeSignInHome()
    defer { try? FileManager.default.removeItem(at: parent) }
    let file = try TakibiKeyFile.write(" pub.secret\n", in: parent)
    #expect(try String(contentsOfFile: file.path, encoding: .utf8) == "pub.secret\n")
    #expect(try signInMode(at: file.path) == 0o600)
    #expect(try signInMode(at: file.folder.path(percentEncoded: false)) == 0o700)
    #expect(throws: TakibiFailure.self) { try TakibiKeyFile.write("nope", in: parent) }

    // A crashed run's folder goes; one this running app made stays until its run ends.
    let crashed = parent.appending(path: "\(TakibiKeyFile.prefix)999999-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
    TakibiKeyFile.removeLeftovers(in: parent)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(!FileManager.default.fileExists(atPath: crashed.path(percentEncoded: false)))
    file.remove()
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false)).isEmpty)
}

@MainActor
@Test func overlappingKeyChangesKeepEveryKey() async throws {
    let store = MemoryKeyStore(["codex": "pub.codex"])
    let service = TakibiService(
        home: URL(filePath: "/nonexistent"),
        keyStore: store,
        runner: { _, _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
        isExecutable: { _ in false },
        fileExists: { _ in false }
    )
    async let refresh: Void = service.refresh()
    async let main: Void = service.saveKey("pub.main")
    async let grok: Void = service.saveKey("pub.grok", for: "grok")
    async let found: Void = service.importKeys(["claude": "pub.claude", "codex": "pub.old"])
    _ = try await (refresh, main, grok, found)
    let expected = ["main": "pub.main", "grok": "pub.grok", "claude": "pub.claude", "codex": "pub.codex"]
    #expect(try store.load() == expected)
    #expect(service.savedKeys == Set(expected.keys))
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
    private var storedKeys: [String?] = []

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var keys: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storedKeys
    }

    func run(_ arguments: [String], key: String?) -> TakibiCommandOutput {
        lock.lock()
        stored.append(arguments)
        storedKeys.append(key)
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
@Test func aPastedAgentKeyGoesToTheKeyStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-agentkey-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-agentkey-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemoryKeyStore()
    let model = DeskModel(
        store: ThreadStore(directory: directory.appending(path: "threads", directoryHint: .isDirectory)),
        runner: EchoAgentRunner(),
        trash: { _ in },
        defaults: defaults,
        supportDirectory: directory,
        takibi: TakibiService(
            home: directory,
            keyStore: store,
            runner: { _, _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
            isExecutable: { _ in false },
            fileExists: { _ in false }
        )
    )

    await #expect(throws: TakibiFailure.self) { try await model.saveAgentKey("not a key", for: .grok) }
    #expect(model.takibi.hasOwnKey(.grok) == false)

    try await model.saveAgentKey("  pub123.secret456\n", for: .grok)
    #expect(model.takibi.hasOwnKey(.grok))
    #expect(try store.load() == ["grok": "pub123.secret456"])

    try await model.removeAgentKey(for: .grok)
    #expect(model.takibi.hasOwnKey(.grok) == false)
    #expect(try store.load().isEmpty)
}

@MainActor
@Test func keyFilesFromEarlierVersionsMoveToTheKeyStoreOnce() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-keymove-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let home = directory.appending(path: "home", directoryHint: .isDirectory)
    let suite = "desk-keymove-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MemoryKeyStore(["codex": "pub.saved"])
    let model = DeskModel(
        store: ThreadStore(directory: directory.appending(path: "threads", directoryHint: .isDirectory)),
        runner: EchoAgentRunner(),
        trash: { _ in },
        defaults: defaults,
        supportDirectory: directory,
        homeDirectory: home,
        takibi: TakibiService(
            home: home,
            keyStore: store,
            runner: { _, _, _ in TakibiCommandOutput(stdout: "", stderr: "", exitCode: 1) },
            isExecutable: { _ in false }
        )
    )
    let grok = model.legacyAgentKeyURL(for: .grok)
    let codex = model.legacyAgentKeyURL(for: .codex)
    let elsewhere = directory.appending(path: "mine.key", directoryHint: .notDirectory)
    try TakibiKey.write("pub.grok", to: grok)
    try TakibiKey.write("pub.codexfile", to: codex)
    try TakibiKey.write("pub.claude", to: elsewhere)
    try TakibiKey.write("pub.main", to: URL(filePath: TakibiPaths.keyFile(home: home)))
    defaults.set(grok.path(percentEncoded: false), forKey: DeskModel.keyFileKey(.grok))
    defaults.set(codex.path(percentEncoded: false), forKey: DeskModel.keyFileKey(.codex))
    defaults.set(elsewhere.path(percentEncoded: false), forKey: DeskModel.keyFileKey(.claude))

    await model.moveKeyFilesToKeychain()
    #expect(try store.load() == ["main": "pub.main", "grok": "pub.grok", "codex": "pub.saved", "claude": "pub.claude"])
    #expect(!FileManager.default.fileExists(atPath: grok.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: codex.path(percentEncoded: false)))
    // ~/.takibi/key goes, since every program falls back to it. Of the agents' files, only irori's go.
    #expect(!FileManager.default.fileExists(atPath: TakibiPaths.keyFile(home: home)))
    #expect(model.takibi.sharedKeyFileExists == false)
    #expect(FileManager.default.fileExists(atPath: elsewhere.path(percentEncoded: false)))
    #expect(defaults.string(forKey: DeskModel.keyFileKey(.grok)) == nil)

    try await model.takibi.removeKey(for: TakibiService.mainKey)
    await model.moveKeyFilesToKeychain()
    #expect(try store.load()["main"] == nil)
}

@Test func grokSaysNotLoggedInMeansSignedOut() {
    #expect(SignInStatus.grok(from: "Not logged in. Run grok login.\n") == .signedOut)
    #expect(SignInStatus.grok(from: "You are logged in with grok.com.\n") == .signedIn("grok.com"))
}

