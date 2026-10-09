import Foundation
import Synchronization
import Testing
@testable import Desk

private typealias DeskThread = Desk.Thread

@Test func searchMatchesTitleBodyAndEveryWord() {
    let thread = DeskThread(title: "Launch plan", messages: [
        Message(author: .user, body: "What about the budget?"),
        Message(author: .agent(.claude), body: "Café costs are low."),
    ])
    #expect(ThreadSearch.matches(thread, query: "launch"))
    #expect(ThreadSearch.matches(thread, query: "BUDGET"))
    #expect(ThreadSearch.matches(thread, query: "launch budget"))
    #expect(!ThreadSearch.matches(thread, query: "launch roadmap"))
    #expect(ThreadSearch.matches(thread, query: "cafe"))
    #expect(ThreadSearch.matches(thread, query: "café"))
    #expect(ThreadSearch.matches(thread, query: ""))
    #expect(ThreadSearch.matches(thread, query: "  \n "))
}

@MainActor
@Suite struct EverydayChatTests {
    private final class Flag {
        var value = false
    }

    @MainActor
    private final class RecordingNotifier: TurnNotifier {
        var onOpen: (@MainActor (DeskThread.ID) -> Void)?
        var posted: [(thread: DeskThread.ID, title: String, body: String)] = []
        var badges: [Int] = []
        func turnFinished(threadID: DeskThread.ID, title: String, body: String) {
            posted.append((threadID, title, body))
        }
        var waiting: [(thread: DeskThread.ID, title: String, body: String)] = []
        func waitingForApproval(threadID: DeskThread.ID, title: String, body: String) {
            waiting.append((threadID, title, body))
        }
        func setBadge(_ count: Int) {
            badges.append(count)
        }
    }

    private func make(
        _ runner: any AgentRunner = ReplyRunner(),
        notifier: any TurnNotifier = NoTurnNotifier(),
        active: @escaping @MainActor () -> Bool = { true }
    ) throws -> (DeskModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "desk-everyday-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = DeskModel(
            store: ThreadStore(directory: directory),
            runner: runner,
            defaults: UserDefaults(suiteName: "desk-everyday-\(UUID().uuidString)")!,
            notifier: notifier,
            isAppActive: active
        )
        return (model, directory)
    }

    private func say(_ model: DeskModel, _ text: String) async throws {
        model.draft = text
        model.send()
        for _ in 0..<300 where model.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isRunning)
    }

    @Test func retryReplacesOnlyTheLastReplyWithAFreshSession() async throws {
        let runner = ReplyRunner()
        let (model, directory) = try make(runner)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        try await say(model, "@claude first")
        try await say(model, "@claude second")
        let thread = try #require(model.selectedThread)
        let first = thread.messages[1].id
        let last = try #require(thread.messages.last)
        #expect(!model.canRetry(first))
        #expect(model.canRetry(last.id))

        model.retry(last.id)
        #expect(model.isRunning)
        #expect(!model.canRetry(last.id))
        for _ in 0..<300 where model.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        let after = try #require(model.selectedThread)
        #expect(after.messages.map(\.body) == ["@claude first", "reply 1", "@claude second", "reply 3"])
        #expect(!after.messages.contains { $0.id == last.id })
        let calls = runner.calls()
        #expect(calls.count == 3)
        #expect(calls[2].session == nil)
        #expect(calls[2].prompt == "User: @claude first\nClaude: reply 1\nUser: @claude second")
        #expect(after.sessions[.claude] == "sess-3")
        #expect(after.cursors[.claude] == 3)
    }

    @Test func retryDropsNoticesAfterTheReply() async throws {
        let (model, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        try await say(model, "@claude hi")
        var thread = try #require(model.selectedThread)
        thread.messages.append(Message(author: .notice, body: "Claude was refused rm."))
        model.threads[0] = thread
        model.retry(thread.messages[1].id)
        for _ in 0..<300 where model.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selectedThread?.messages.map(\.body) == ["@claude hi", "reply 2"])
    }

    @Test func retryIsRefusedWhileRunning() async throws {
        let (model, directory) = try make(StallRunner())
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        model.draft = "@claude hi"
        model.send()
        try await Task.sleep(for: .milliseconds(50))
        let reply = try #require(model.selectedThread?.messages.last)
        #expect(!model.canRetry(reply.id))
        #expect(!model.canEdit(model.selectedThread!.messages[0].id))
        model.stop()
        for _ in 0..<300 where model.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func editRestoresTheDraftAndResetsOnlyAgentsPastTheCut() async throws {
        let (model, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        try await say(model, "@claude one")
        try await say(model, "@grok two")
        var thread = try #require(model.selectedThread)
        #expect(thread.cursors[.claude] == 1)
        #expect(thread.cursors[.grok] == 3)
        #expect(!model.canEdit(thread.messages[0].id))
        let user = thread.messages[2]
        thread = try #require(model.selectedThread)
        model.edit(user.id)

        let after = try #require(model.selectedThread)
        #expect(after.messages.map(\.body) == ["@claude one", "reply 1"])
        #expect(model.draft == "@grok two")
        #expect(after.cursors[.claude] == 1)
        #expect(after.sessions[.claude] == "sess-1")
        #expect(after.cursors[.grok] == nil)
        #expect(after.sessions[.grok] == nil)
        #expect(try ThreadStore(directory: directory).load()[0].messages.count == 2)
    }

    @Test func editingTheOnlyMessageKeepsTheTitle() async throws {
        let (model, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        try await say(model, "@claude hello")
        model.edit(model.selectedThread!.messages[0].id)
        #expect(model.selectedThread?.messages.isEmpty == true)
        #expect(model.selectedThread?.title == "@claude hello")
        #expect(model.draft == "@claude hello")
    }

    @Test func notifiesOncePerSendOnlyWhileInactive() async throws {
        let notifier = RecordingNotifier()
        let flag = Flag()
        let (model, directory) = try make(notifier: notifier, active: { flag.value })
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        let id = try #require(model.selection)

        flag.value = true
        try await say(model, "@claude hi")
        #expect(notifier.posted.isEmpty)
        #expect(model.unreadThreads.isEmpty)

        flag.value = false
        try await say(model, "@claude @grok again")
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted[0].thread == id)
        #expect(notifier.posted[0].title == "@claude hi")
        #expect(notifier.posted[0].body == "reply 3")
        #expect(model.unreadThreads == [id])
    }

    @Test func finishedRepliesDoNotReorderTheSidebar() async throws {
        let (model, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        let first = try #require(model.selection)
        try await say(model, "@claude one")
        model.newThread()
        try await say(model, "@claude two")
        let second = try #require(model.selection)
        #expect(model.visibleThreads.map(\.id) == [second, first])

        let thread = try #require(model.threads.first { $0.id == second })
        let reply = try #require(thread.messages.last { $0.author == .agent(.claude) })
        #expect(thread.updatedAt < (reply.finishedAt ?? .distantPast))
    }

    @Test func unreadCountAndBadgeClearOnSelection() async throws {
        let notifier = RecordingNotifier()
        let (model, directory) = try make(notifier: notifier, active: { false })
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        let first = try #require(model.selection)
        try await say(model, "@claude one")
        model.newThread()
        let second = try #require(model.selection)
        try await say(model, "@claude two")
        #expect(model.unreadThreads == [first, second])
        #expect(notifier.badges.last == 2)

        model.selection = first
        #expect(model.unreadThreads == [second])
        #expect(notifier.badges.last == 1)
        model.selection = second
        #expect(model.unreadThreads.isEmpty)
        #expect(notifier.badges.last == 0)
    }

    @Test func previousAndNextFollowSidebarOrderWithoutWrapping() throws {
        let (model, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date.now
        model.threads = [
            DeskThread(title: "old", updatedAt: now.addingTimeInterval(-20)),
            DeskThread(title: "new", updatedAt: now),
            DeskThread(title: "mid", updatedAt: now.addingTimeInterval(-10)),
        ]
        model.selection = model.visibleThreads[0].id
        model.selectAdjacentThread(-1)
        #expect(model.selectedThread?.title == "new")
        model.selectAdjacentThread(1)
        #expect(model.selectedThread?.title == "mid")
        model.selectAdjacentThread(1)
        #expect(model.selectedThread?.title == "old")
        model.selectAdjacentThread(1)
        #expect(model.selectedThread?.title == "old")
    }

    @Test func searchNarrowsTheSidebarOnTopOfTheArchiveFilter() throws {
        let (model, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.threads = [
            DeskThread(title: "Budget"),
            DeskThread(title: "Budget old", archivedAt: .now),
            DeskThread(title: "Roadmap"),
        ]
        model.searchText = "budget"
        #expect(model.visibleThreads.map(\.title) == ["Budget"])
        model.showsArchived = true
        #expect(model.visibleThreads.map(\.title) == ["Budget old"])
    }
}

private final class ReplyRunner: AgentRunner, Sendable {
    struct Call: Sendable {
        var prompt: String
        var session: String?
    }

    private let recorded = Mutex<[Call]>([])

    func run(agent _: AgentID, prompt: String, session: String?, workspace _: URL, model _: String?, effort _: String?, permissions _: AgentPermissions, executable _: URL?, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        let count = recorded.withLock { calls -> Int in
            calls.append(Call(prompt: prompt, session: session))
            return calls.count
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("reply \(count)"))
            continuation.yield(.session("sess-\(count)"))
            continuation.finish()
        }
    }

    func calls() -> [Call] {
        recorded.withLock { $0 }
    }
}

private struct StallRunner: AgentRunner {
    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort _: String?, permissions _: AgentPermissions, executable _: URL?, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
