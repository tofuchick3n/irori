import Foundation
import Synchronization
import Testing
@testable import Desk

@MainActor
@Test func availabilityUsesCandidatesAndOverrides() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-avail-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let suite = "desk-avail-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let claude = try makeExecutable(URL(filePath: ClaudeCommand.candidatePaths(home: home)[0]))
    let model = try probedModel(directory: root.appending(path: "threads"), home: home, defaults: defaults)
    #expect(model.availability[.claude]?.binary == claude)
    #expect(model.availability[.claude]?.isInstalled == true)
    #expect(model.availability[.codex]?.isInstalled == false)
    #expect(model.availability[.grok]?.isInstalled == false)
    #expect(model.availability[.muse]?.isInstalled == false)
    #expect(model.binaryOverride(for: .grok) == nil)

    let grok = try makeExecutable(home.appending(path: "bin/grok"))
    model.setBinaryOverride("~/bin/grok", for: .grok)
    #expect(model.binaryOverride(for: .grok) == "~/bin/grok")
    #expect(model.availability[.grok]?.binary == grok)
    #expect(model.activeAgents == [.claude, .grok])

    model.setBinaryOverride(home.appending(path: "missing/claude").path(percentEncoded: false), for: .claude)
    #expect(model.availability[.claude]?.isInstalled == false)
    #expect(!model.activeAgents.contains(.claude))

    model.setBinaryOverride(nil, for: .claude)
    #expect(model.binaryOverride(for: .claude) == nil)
    #expect(model.availability[.claude]?.binary == claude)

    let relaunched = try probedModel(directory: root.appending(path: "threads"), home: home, defaults: defaults)
    #expect(relaunched.binaryOverride(for: .grok) == "~/bin/grok")
    #expect(relaunched.availability[.grok]?.binary == grok)
    #expect(relaunched.isEnabled(.claude))
}

@MainActor
@Test func enabledAndPermissionsPersistAndStayAtTheirDefaults() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-prefs-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "desk-prefs-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = DeskModel(store: ThreadStore(directory: root), runner: MilestoneRunner(), trash: { _ in }, defaults: defaults)
    #expect(model.allowsFileWrites)
    #expect(model.allowedCommands == ["takibi"])
    #expect(model.isEnabled(.muse))
    model.setEnabled(false, for: .muse)
    model.allowsFileWrites = false
    model.allowedCommands = []

    let again = DeskModel(store: ThreadStore(directory: root), runner: MilestoneRunner(), trash: { _ in }, defaults: defaults)
    #expect(!again.isEnabled(.muse))
    #expect(again.isEnabled(.claude))
    #expect(!again.allowsFileWrites)
    #expect(again.allowedCommands.isEmpty)
    #expect(again.defaultAgent == .claude)
}

@MainActor
@Test func inactiveAgentsAreSkippedWithTheSpecifiedNotices() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-inactive-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "desk-inactive-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = MilestoneRunner()
    let model = DeskModel(store: ThreadStore(directory: root), runner: runner, trash: { _ in }, defaults: defaults)
    model.newThread()

    model.setEnabled(false, for: .grok)
    model.setEnabled(false, for: .muse)
    model.draft = "@all go"
    model.send()
    try await settle(model)
    #expect(runner.calls().map(\.agent) == [.claude, .codex])
    #expect(notices(in: model).isEmpty)

    model.setEnabled(false, for: .muse)
    model.draft = "@muse @claude hi"
    model.send()
    try await settle(model)
    #expect(notices(in: model) == ["Muse is turned off in Settings."])
    #expect(runner.calls().map(\.agent) == [.claude, .codex, .claude])
}

@MainActor
@Test func aMissingAgentIsSkippedAndNoneActiveStopsTheSend() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let suite = "desk-missing-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = try makeExecutable(URL(filePath: ClaudeCommand.candidatePaths(home: home)[0]))
    let runner = MilestoneRunner()
    let model = try probedModel(
        directory: root.appending(path: "threads"),
        home: home,
        defaults: defaults,
        runner: runner
    )
    model.newThread()
    model.draft = "@grok"
    model.send()
    try await settle(model)
    #expect(notices(in: model) == ["Grok isn't installed."])
    #expect(runner.calls().isEmpty)
    #expect(model.selectedThread?.messages.contains { $0.author == .user && $0.body == "@grok" } == true)

    model.draft = "@grok @claude"
    model.send()
    try await settle(model)
    #expect(notices(in: model) == ["Grok isn't installed.", "Grok isn't installed."])
    #expect(runner.calls().map(\.agent) == [.claude])

    model.setEnabled(false, for: .grok)
    model.draft = "@grok"
    model.send()
    try await settle(model)
    #expect(notices(in: model).last == "Grok is turned off in Settings.")

    for agent in AgentID.allCases {
        model.setEnabled(false, for: agent)
    }
    #expect(model.defaultAgent == .claude)
    #expect(model.effectiveDefaultAgent == nil)
    #expect(model.activeAgents.isEmpty)
    model.draft = "hi"
    model.send()
    try await settle(model)
    #expect(!model.isRunning)
    #expect(runner.calls().map(\.agent) == [.claude])
    #expect(model.selectedThread?.messages.contains { $0.author == .user && $0.body == "hi" } == true)
    #expect(notices(in: model).last == "No agents are available. Install one, or turn one on in Settings.")
}

@MainActor
@Test func theFallbackIsTheDefaultAgentWhenActiveOtherwiseTheFirstActiveAgent() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-fallback-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "desk-fallback-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = MilestoneRunner()
    let model = DeskModel(store: ThreadStore(directory: root), runner: runner, trash: { _ in }, defaults: defaults)
    model.newThread()
    model.setEnabled(false, for: .claude)
    #expect(model.defaultAgent == .claude)
    #expect(model.effectiveDefaultAgent == .codex)
    model.draft = "hello"
    #expect(model.nextRecipients == [.codex])
    model.send()
    try await settle(model)
    #expect(runner.calls().map(\.agent) == [.codex])
    #expect(notices(in: model).isEmpty)

    model.setEnabled(true, for: .claude)
    model.draft = "@grok @claude first"
    model.send()
    try await settle(model)
    model.setEnabled(false, for: .grok)
    model.draft = "follow up"
    #expect(model.nextRecipients == [.claude])
    model.send()
    try await settle(model)
    #expect(runner.calls().map(\.agent) == [.codex, .grok, .claude, .claude])
}

@MainActor
@Test func aRunReceivesPermissionsAndOnlyAnOverridePath() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-run-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let suite = "desk-run-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = try makeExecutable(URL(filePath: ClaudeCommand.candidatePaths(home: home)[0]))
    let grok = try makeExecutable(home.appending(path: "bin/grok"))
    let runner = MilestoneRunner()
    let model = try probedModel(
        directory: root.appending(path: "threads"),
        home: home,
        defaults: defaults,
        runner: runner
    )
    model.allowsFileWrites = false
    model.allowedCommands = [" git ", "git", "", "takibi"]
    #expect(model.allowedCommands == ["git", "takibi"])
    model.setBinaryOverride("~/bin/grok", for: .grok)
    model.newThread()
    model.draft = "@claude @grok"
    model.send()
    try await settle(model)

    let calls = runner.calls()
    #expect(calls.map(\.agent) == [.claude, .grok])
    #expect(calls.allSatisfy {
        $0.permissions == AgentPermissions(allowsFileWrites: false, allowedCommands: ["git", "takibi"], allowedRules: ["WebSearch", "WebFetch"])
    })
    let claude = try #require(calls.first)
    let grokCall = try #require(calls.dropFirst().first)
    #expect(claude.executable == nil)
    #expect(grokCall.executable == grok)
}

@MainActor
@Test func catalogRefreshQueriesOnlyActiveAgents() async {
    let catalog = ModelCatalog()
    catalog.activeAgents = [.claude]
    await catalog.refresh()
    #expect(catalog.refreshedAgents == [.claude])
    #expect(!(catalog.options[.claude] ?? []).isEmpty)
    #expect(catalog.options[.codex]?.isEmpty == true)
    #expect(catalog.options[.grok]?.isEmpty == true)
    #expect(catalog.options[.muse]?.isEmpty == true)
}

private struct MilestoneCall: Equatable, Sendable {
    var agent: AgentID
    var permissions: AgentPermissions
    var executable: URL?
}

private final class MilestoneRunner: AgentRunner, Sendable {
    private let recorded = Mutex<[MilestoneCall]>([])

    func calls() -> [MilestoneCall] { recorded.withLock { $0 } }

    func run(
        agent: AgentID,
        prompt _: String,
        session _: String?,
        workspace _: URL,
        model _: String?,
        effort _: String?,
        permissions: AgentPermissions,
        executable: URL?,
        approve _: @escaping ApprovalHandler
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        recorded.withLock { $0.append(MilestoneCall(agent: agent, permissions: permissions, executable: executable)) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("ok"))
            continuation.finish()
        }
    }
}

@MainActor
private func probedModel(
    directory: URL,
    home: URL,
    defaults: UserDefaults,
    runner: MilestoneRunner = MilestoneRunner()
) throws -> DeskModel {
    var trimmed = home.path(percentEncoded: false)
    if trimmed.count > 1, trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    let root = trimmed
    return DeskModel(
        store: ThreadStore(directory: directory),
        runner: runner,
        trash: { _ in },
        defaults: defaults,
        homeDirectory: home,
        isExecutable: { path in
            guard path == root || path.hasPrefix(root + "/") else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        },
        assumeInstalled: false
    )
}

private func makeExecutable(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    return url
}

@MainActor
private func settle(_ model: DeskModel) async throws {
    for _ in 0..<200 where model.isRunning {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isRunning)
}

@MainActor
private func notices(in model: DeskModel) -> [String] {
    model.selectedThread?.messages.compactMap { message in
        message.author == .notice ? message.body : nil
    } ?? []
}

@MainActor
@Test func choosingWhoRepliesNextOverridesAnEarlierMention() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-next-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "desk-next-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let runner = MilestoneRunner()
    let model = DeskModel(store: ThreadStore(directory: root), runner: runner, trash: { _ in }, defaults: defaults)
    model.newThread()
    model.setDefaultAgent(.muse)
    model.draft = "@claude first"
    model.send()
    try await settle(model)
    model.draft = "follow up"
    #expect(model.nextRecipients == [.claude])

    model.chooseNextReplier(.muse)
    #expect(model.defaultAgent == .muse)
    #expect(model.nextRecipients == [.muse])
    model.send()
    try await settle(model)
    #expect(runner.calls().map(\.agent) == [.claude, .muse])

    let reloaded = try ThreadStore(directory: root).load()
    #expect(reloaded.first?.mentionsFrom == 2)
}

@MainActor
@Test func forgettingEarlierMentionsHandsTheThreadBackToTheDefault() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-forget-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "desk-forget-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = DeskModel(store: ThreadStore(directory: root), runner: MilestoneRunner(), trash: { _ in }, defaults: defaults)
    model.newThread()
    model.setDefaultAgent(.muse)
    model.draft = "@claude and @muse first"
    #expect(!model.repliersCarryOver)
    model.send()
    try await settle(model)

    model.draft = "follow up"
    #expect(model.nextRecipients == [.claude, .muse])
    #expect(model.repliersCarryOver)

    model.forgetEarlierMentions()
    #expect(model.nextRecipients == [.muse])
    #expect(model.defaultAgent == .muse)
    #expect(!model.repliersCarryOver)
}

@MainActor
@Test func forgettingMentionsKeepsTheTitleAndEditedMentionsStillCount() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-forget-title-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "desk-forget-title-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = DeskModel(store: ThreadStore(directory: root), runner: MilestoneRunner(), trash: { _ in }, defaults: defaults)
    model.newThread()
    model.setDefaultAgent(.muse)
    model.draft = "@claude plan the launch"
    model.send()
    try await settle(model)
    let title = model.selectedThread?.title

    model.forgetEarlierMentions()
    model.draft = "now the copy"
    model.send()
    try await settle(model)
    #expect(model.selectedThread?.title == title)

    model.draft = "@claude and the pricing"
    model.send()
    try await settle(model)
    model.forgetEarlierMentions()
    let last = try #require(model.selectedThread?.messages.last { $0.author == .user })
    model.edit(last.id)
    #expect(model.draft == "@claude and the pricing")
    model.send()
    try await settle(model)
    model.draft = "follow up"
    #expect(model.nextRecipients == [.claude])
}
