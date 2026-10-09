import Foundation
import Testing
@testable import Desk

@Test func examplePromptsFollowTheActiveAgents() {
    #expect(ExamplePrompts.make(active: []).isEmpty)
    #expect(ExamplePrompts.make(active: [.grok]) == [
        "@grok Poke holes in this idea: ",
        "@grok Compare two ways to ",
        "@grok Argue the opposite of ",
    ])
    #expect(ExamplePrompts.make(active: [.claude, .codex]) == [
        "@all Poke holes in this idea: ",
        "@claude @codex Compare two ways to ",
        "@codex Argue the opposite of ",
    ])
    #expect(ExamplePrompts.make(active: [.claude, .codex, .muse]) == [
        "@all Poke holes in this idea: ",
        "@claude @codex Compare two ways to ",
        "@muse Argue the opposite of ",
    ])
}

@Test func welcomeStatusCoversEveryState() throws {
    let found = AgentAvailability(binary: URL(filePath: "/usr/bin/true"))
    let missing = AgentAvailability(binary: nil)

    let claudeMissing = WelcomeStatus.make(agent: .claude, availability: missing, signIn: nil)
    #expect(claudeMissing.label == "Not installed")
    #expect(claudeMissing.action == .get(try #require(AgentID.claude.installURL)))
    #expect(WelcomeStatus.make(agent: .muse, availability: missing, signIn: nil).action == nil)
    #expect(WelcomeStatus.make(agent: .grok, availability: nil, signIn: nil).label == "Not installed")

    let signedOut = WelcomeStatus.make(agent: .codex, availability: found, signIn: .signedOut)
    #expect(signedOut.label == "Not signed in")
    #expect(signedOut.action == .signIn)
    #expect(!signedOut.isReady)

    let unknown = WelcomeStatus.make(agent: .codex, availability: found, signIn: .unknown)
    #expect(unknown.label == "Couldn't check")
    #expect(unknown.action == .checkAgain)

    let off = WelcomeStatus.make(agent: .codex, availability: found, signIn: nil, isEnabled: false)
    #expect(off.label == "Turned off in Settings")
    #expect(off.action == nil)
    #expect(!off.isReady)

    let ready = WelcomeStatus.make(agent: .codex, availability: found, signIn: .signedIn("ChatGPT"))
    #expect(ready.label == "Ready")
    #expect(ready.detail == "ChatGPT")
    #expect(ready.action == nil)
    #expect(ready.isReady)
}

@MainActor
@Test func welcomeIsSeenOnceAndGetStartedMakesAThread() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-welcome-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "desk-welcome-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = DeskModel(store: ThreadStore(directory: root), runner: FailingRunner(error: AgentRunError(message: "x")), trash: { _ in }, defaults: defaults)
    #expect(!model.hasSeenWelcome)
    #expect(!model.hasReadyAgent)
    model.signIn[.claude] = .signedIn(nil)
    #expect(model.hasReadyAgent)
    #expect(model.threads.isEmpty)
    model.completeWelcome()
    #expect(model.hasSeenWelcome)
    #expect(model.threads.count == 1)

    let again = DeskModel(store: ThreadStore(directory: root), runner: FailingRunner(error: AgentRunError(message: "x")), trash: { _ in }, defaults: defaults)
    #expect(again.hasSeenWelcome)
}

@MainActor
@Test func aMissingCLIGetsAnOpenSettingsNotice() async throws {
    let (model, root, defaults, suite) = try failingModel(
        error: AgentRunError(message: "claude was not found in ~/.local/bin.", notInstalled: true),
        signedOut: false
    )
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    try await sendHello(model)
    let notice = try #require(model.selectedThread?.messages.last { $0.author == .notice })
    #expect(notice.body == "Claude isn't installed.")
    #expect(notice.fix == .openSettings)
    #expect(notice.fixAgent == .claude)

    model.performFix(notice)
    #expect(model.settingsTab == "Agents")
}

@MainActor
@Test func aSignedOutAgentGetsASignInNotice() async throws {
    let (model, root, defaults, suite) = try failingModel(error: AgentRunError(message: "please log in"), signedOut: true)
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    try await sendHello(model)
    let notice = try #require(model.selectedThread?.messages.last { $0.author == .notice })
    #expect(notice.body == "Claude isn't signed in.")
    #expect(notice.fix == .signIn)
    #expect(notice.fixAgent == .claude)
    #expect(model.signIn[.claude] == .signedOut)
}

@MainActor
@Test func otherFailuresKeepTheirOwnNotice() async throws {
    let (model, root, defaults, suite) = try failingModel(error: AgentRunError(message: "rate limited"), signedOut: false)
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    try await sendHello(model)
    let notice = try #require(model.selectedThread?.messages.last { $0.author == .notice })
    #expect(notice.body == "rate limited")
    #expect(notice.fix == nil)
}

@Test func oldMessagesWithoutAFixStillDecode() throws {
    let json = """
    {"id":"\(UUID().uuidString)","author":{"notice":{}},"body":"hi","createdAt":0}
    """
    let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
    #expect(message.fix == nil)
    #expect(message.fixAgent == nil)

    var notice = Message(author: .notice, body: "Claude isn't signed in.")
    notice.fix = .signIn
    notice.fixAgent = .claude
    let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(notice))
    #expect(decoded.fix == .signIn)
    #expect(decoded.fixAgent == .claude)
}

private struct FailingRunner: AgentRunner {
    let error: AgentRunError

    func run(
        agent _: AgentID,
        prompt _: String,
        session _: String?,
        workspace _: URL,
        model _: String?,
        effort _: String?,
        permissions _: AgentPermissions,
        executable _: URL?,
        approve _: @escaping ApprovalHandler
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

@MainActor
private func failingModel(error: AgentRunError, signedOut: Bool) throws -> (DeskModel, URL, UserDefaults, String) {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-fix-\(UUID().uuidString)", directoryHint: .isDirectory)
    let suite = "desk-fix-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let stdout = signedOut ? #"{"loggedIn":false}"# : #"{"loggedIn":true}"#
    let model = DeskModel(
        store: ThreadStore(directory: root),
        runner: FailingRunner(error: error),
        trash: { _ in },
        defaults: defaults,
        signInProbe: { _, _ in SignInOutput(stdout: stdout, exitCode: 0) }
    )
    model.newThread()
    return (model, root, defaults, suite)
}

@MainActor
private func sendHello(_ model: DeskModel) async throws {
    model.draft = "@claude hello"
    model.send()
    for _ in 0..<300 where model.isRunning {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isRunning)
}

@MainActor
@Test func welcomeHidesMissingAgentsWithNowhereToGetThem() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-welcome-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "desk-welcome-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = DeskModel(store: ThreadStore(directory: root), runner: EchoAgentRunner(), trash: { _ in }, defaults: defaults)

    let found = AgentAvailability(binary: URL(filePath: "/usr/bin/true"))
    let missing = AgentAvailability(binary: nil)
    model.availability = [.claude: missing, .codex: missing, .grok: found, .muse: missing]
    #expect(model.welcomeAgents == [.claude, .codex, .grok])
}
