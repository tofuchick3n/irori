import Foundation
import Synchronization
import Testing
@testable import Desk

/// Each run waits until the test finishes it, so a turn stays in progress as long as needed.
private final class HoldingRunner: AgentRunner, Sendable {
    private let state = Mutex<(prompts: [String], open: [AsyncThrowingStream<AgentEvent, Error>.Continuation])>(([], []))

    var prompts: [String] { state.withLock { $0.prompts } }

    func run(agent _: AgentID, prompt: String, session _: String?, workspace _: URL, model _: String?, effort _: String?, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            state.withLock {
                $0.prompts.append(prompt)
                $0.open.append(continuation)
            }
        }
    }

    func finishOldest() {
        let continuation = state.withLock { $0.open.isEmpty ? nil : $0.open.removeFirst() }
        continuation?.yield(.text("ok"))
        continuation?.finish()
    }
}

@MainActor
private func makeModel(_ runner: HoldingRunner) throws -> (DeskModel, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
    let suite = "desk-queue-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let model = DeskModel(store: ThreadStore(directory: directory), runner: runner, trash: { _ in }, defaults: defaults)
    return (model, {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    })
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func startTurn(_ model: DeskModel, _ runner: HoldingRunner, _ text: String = "@claude first") async throws {
    model.draft = text
    model.send()
    try await waitUntil { !runner.prompts.isEmpty && model.isRunning }
}

@MainActor
@Test func sendingWhileRunningQueuesInsteadOfRunning() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let thread = try #require(model.selection)
    try await startTurn(model, runner)

    model.draft = "@claude later"
    model.send()

    #expect(model.draft.isEmpty)
    #expect(model.queuedMessage(in: thread)?.text == "@claude later")
    #expect(model.selectedThread?.messages.contains { $0.body == "@claude later" } == false)
    #expect(runner.prompts.count == 1)

    runner.finishOldest()
    runner.finishOldest()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func aSecondSendInTheSameThreadIsRefusedWhileOneIsQueued() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let thread = try #require(model.selection)
    try await startTurn(model, runner)
    model.draft = "one"
    model.send()

    model.draft = "two"
    model.send()

    #expect(model.draft == "two")
    #expect(model.queue.count == 1)
    #expect(model.queuedMessage(in: thread)?.text == "one")

    model.stop()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func queuedMessagesRunOneAtATimeInTheOrderTheyWereQueued() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let first = try #require(model.selection)
    try await startTurn(model, runner)
    model.newThread()
    let second = try #require(model.selection)
    model.draft = "@claude from second"
    model.send()
    model.selection = first
    model.draft = "@claude from first"
    model.send()
    #expect(model.queue.map(\.threadID) == [second, first])

    runner.finishOldest()
    try await waitUntil { runner.prompts.count == 2 }
    #expect(runner.prompts[1].contains("from second"))
    #expect(model.runningThreadID == second)
    #expect(model.queue.map(\.threadID) == [first])
    #expect(model.threads.first { $0.id == second }?.messages.first?.body == "@claude from second")

    runner.finishOldest()
    try await waitUntil { runner.prompts.count == 3 }
    #expect(runner.prompts[2].contains("from first"))
    #expect(model.runningThreadID == first)
    #expect(model.queue.isEmpty)

    runner.finishOldest()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func cancellingAQueuedMessageRestoresTheDraft() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let thread = try #require(model.selection)
    try await startTurn(model, runner)
    model.draft = "hold this"
    model.send()

    model.cancelQueued(in: thread)

    #expect(model.queue.isEmpty)
    #expect(model.draft == "hold this")

    model.stop()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func cancellingKeepsWhatWasTypedSince() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let thread = try #require(model.selection)
    try await startTurn(model, runner)
    model.draft = "queued"
    model.send()
    model.draft = "typing"

    model.cancelQueued(in: thread)

    #expect(model.queue.isEmpty)
    #expect(model.draft == "typing\n\nqueued")

    model.stop()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func stoppingClearsTheQueueAndRestoresTheSelectedThreadsText() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    try await startTurn(model, runner)
    model.draft = "after"
    model.send()

    model.stop()
    try await waitUntil { !model.isRunning }

    #expect(model.queue.isEmpty)
    #expect(model.draft == "after")
    #expect(runner.prompts.count == 1)
}

@MainActor
@Test func deletingAThreadDropsItsQueuedMessage() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let running = try #require(model.selection)
    try await startTurn(model, runner)
    model.newThread()
    let other = try #require(model.selection)
    model.draft = "waiting"
    model.send()
    #expect(model.queuedMessage(in: other) != nil)

    model.delete(other)

    #expect(model.queue.isEmpty)
    #expect(model.threads.contains { $0.id == running })

    runner.finishOldest()
    try await waitUntil { !model.isRunning }
    #expect(runner.prompts.count == 1)
}

@MainActor
@Test func deletingTheRunningThreadKeepsOtherQueuedMessagesAndSendsThem() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let running = try #require(model.selection)
    try await startTurn(model, runner)

    model.newThread()
    let waiting = try #require(model.selection)
    model.draft = "@claude after"
    model.send()
    #expect(model.queuedMessage(in: waiting) != nil)

    model.delete(running)
    try await waitUntil { runner.prompts.count == 2 }
    #expect(model.queuedMessage(in: waiting) == nil)
    #expect(model.threads.first { $0.id == waiting }?.messages.contains { $0.body == "@claude after" } == true)
    runner.finishOldest()
    runner.finishOldest()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func stoppingRestoresQueuedTextToEveryThreadNotJustTheOpenOne() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let running = try #require(model.selection)
    try await startTurn(model, runner)
    model.newThread()
    let other = try #require(model.selection)
    model.draft = "for later"
    model.send()
    model.selection = running

    model.stop()
    try await waitUntil { !model.isRunning }

    #expect(model.queue.isEmpty)
    #expect(model.drafts[other] == "for later")
}

@MainActor
@Test func aMessageSentWhileStoppingStillGoesOut() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    try await startTurn(model, runner)

    model.stop()
    model.draft = "@claude right after"
    model.send()

    try await waitUntil { runner.prompts.count == 2 }
    #expect(runner.prompts.count == 2)
    #expect(model.queue.isEmpty)
    runner.finishOldest()
    runner.finishOldest()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func sendNowCutsTheTurnShortAndGoesAheadOfTheQueue() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let running = try #require(model.selection)
    try await startTurn(model, runner)
    model.newThread()
    let other = try #require(model.selection)
    model.draft = "@claude waiting"
    model.send()
    model.selection = running

    model.draft = "@claude urgent"
    model.sendNow()

    try await waitUntil { runner.prompts.count == 2 }
    #expect(runner.prompts.last?.contains("urgent") == true)
    #expect(model.queuedMessage(in: other)?.text == "@claude waiting")
    // The interrupted turn's stream is still the oldest; the urgent one is next.
    runner.finishOldest()
    runner.finishOldest()
    try await waitUntil { runner.prompts.count == 3 }
    #expect(runner.prompts.last?.contains("waiting") == true)
    runner.finishOldest()
    runner.finishOldest()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func sendNowWithNothingTypedSendsTheQueuedMessage() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let thread = try #require(model.selection)
    try await startTurn(model, runner)
    model.draft = "@claude queued"
    model.send()

    model.sendNow()

    try await waitUntil { runner.prompts.count == 2 }
    #expect(model.queuedMessage(in: thread) == nil)
    #expect(runner.prompts.last?.contains("queued") == true)
    runner.finishOldest()
    runner.finishOldest()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func sendNowWithAQueuedMessageAndNewTextSendsBothAsOne() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    let thread = try #require(model.selection)
    try await startTurn(model, runner)
    model.draft = "@claude first part"
    model.send()

    model.draft = "second part"
    model.sendNow()

    try await waitUntil { runner.prompts.count == 2 }
    #expect(model.queuedMessage(in: thread) == nil)
    #expect(model.draft.isEmpty)
    #expect(runner.prompts.last?.contains("first part") == true)
    #expect(runner.prompts.last?.contains("second part") == true)
    runner.finishOldest()
    runner.finishOldest()
    try await waitUntil { !model.isRunning }
}

@MainActor
@Test func newThreadDoesNotReuseAnEmptyThreadWithAQueuedMessage() async throws {
    let runner = HoldingRunner()
    let (model, cleanup) = try makeModel(runner)
    defer { cleanup() }
    model.newThread()
    try await startTurn(model, runner)
    model.newThread()
    let waiting = try #require(model.selection)
    model.draft = "@claude later"
    model.send()

    model.newThread()

    #expect(model.selection != waiting)
    model.stop()
    try await waitUntil { !model.isRunning }
}
