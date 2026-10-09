import Foundation
import Synchronization
import Testing
@testable import Desk

@MainActor
@Test func aSavedEffortIsUsedBeforeTheCatalogLoads() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-effort-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-effort-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("low", forKey: "effort.grok")

    let runner = EffortRecordingRunner()
    let model = DeskModel(store: ThreadStore(directory: directory), runner: runner, trash: { _ in }, defaults: defaults)
    #expect((model.catalog.options[.grok] ?? []).isEmpty)
    model.newThread()
    model.draft = "@grok hi"
    model.send()
    for _ in 0..<200 where model.isRunning {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(runner.efforts() == ["low"])
}

private final class EffortRecordingRunner: AgentRunner, Sendable {
    private let recorded = Mutex<[String?]>([])

    func efforts() -> [String?] { recorded.withLock { $0 } }

    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort: String?, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        recorded.withLock { $0.append(effort) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("ok"))
            continuation.finish()
        }
    }
}

@MainActor
@Test func theDefaultAgentIsRememberedAndAnswersANewThread() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-default-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-default-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let model = DeskModel(store: ThreadStore(directory: directory), runner: EffortRecordingRunner(), trash: { _ in }, defaults: defaults)
    #expect(model.defaultAgent == .claude)
    model.setDefaultAgent(.codex)
    model.newThread()
    model.draft = "hello"
    #expect(model.nextRecipients == [.codex])

    let relaunched = DeskModel(store: ThreadStore(directory: directory), runner: EffortRecordingRunner(), trash: { _ in }, defaults: defaults)
    #expect(relaunched.defaultAgent == .codex)
}
