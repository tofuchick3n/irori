import Foundation
import Synchronization
import Testing
@testable import Desk

@MainActor
@Suite struct DeskModelTests {
    @Test func agentsReplyInOrderAndCursorsAdvance() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = RecordingRunner()
        let model = DeskModel(store: ThreadStore(directory: directory), runner: runner)
        model.newThread()
        model.draft = "@grok @claude hi"
        model.send()
        try await waitUntilIdle(model)

        let thread = try #require(model.selectedThread)
        #expect(thread.title == "@grok @claude hi")
        #expect(thread.messages.map(\.body) == ["@grok @claude hi", "hello", "hello"])
        #expect(thread.messages.map(\.author) == [.user, .agent(.grok), .agent(.claude)])
        #expect(thread.cursors[.grok] == 1)
        #expect(thread.cursors[.claude] == 2)
        #expect(thread.sessions[.grok] == "sess-grok")
        #expect(thread.sessions[.claude] == "sess-claude")
        #expect(runner.prompts().map(\.0) == [.grok, .claude])
        #expect(runner.prompts().map(\.1) == [
            "User: @grok @claude hi",
            "User: @grok @claude hi\nGrok: hello",
        ])
        #expect(runner.sessions() == [nil, nil])

        model.draft = "next"
        model.send()
        try await waitUntilIdle(model)

        let continued = try #require(model.selectedThread)
        #expect(continued.title == "@grok @claude hi")
        #expect(runner.prompts().map(\.0) == [.grok, .claude, .grok, .claude])
        #expect(runner.prompts().map(\.1) == [
            "User: @grok @claude hi",
            "User: @grok @claude hi\nGrok: hello",
            "Claude: hello\nUser: next",
            "User: next\nGrok: hello",
        ])
        #expect(runner.sessions() == [nil, nil, "sess-grok", "sess-claude"])
        #expect(continued.cursors[.grok] == 4)
        #expect(continued.cursors[.claude] == 5)

        let restored = try ThreadStore(directory: directory).load()
        #expect(restored.map(\.id) == [continued.id])
        #expect(restored[0].messages.map(\.body) == continued.messages.map(\.body))
        #expect(restored[0].cursors == continued.cursors)
        #expect(restored[0].sessions == continued.sessions)
    }

    @Test func stopKeepsPartialTextAndSkipsQueuedAgents() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DeskModel(store: ThreadStore(directory: directory), runner: HangingRunner())
        model.newThread()
        model.draft = "@grok @claude hi"
        model.send()

        var sawPartial = false
        for _ in 0..<100 {
            if model.selectedThread?.messages.contains(where: { $0.body == "partial-grok" }) == true {
                sawPartial = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawPartial)
        model.stop()
        try await waitUntilIdle(model)

        let thread = try #require(model.selectedThread)
        #expect(thread.messages.map(\.body) == ["@grok @claude hi", "partial-grok"])
        #expect(thread.messages.map(\.author) == [.user, .agent(.grok)])
        let restored = try ThreadStore(directory: directory).load().first
        #expect(restored?.messages.map(\.body) == thread.messages.map(\.body))
    }

    @Test func emptyReplyLeavesANoticeAndDoesNotAdvanceCursor() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = SilentRunner()
        let model = DeskModel(store: ThreadStore(directory: directory), runner: runner)
        model.newThread()
        model.draft = "@grok hi"
        model.send()
        try await waitUntilIdle(model)

        let thread = try #require(model.selectedThread)
        #expect(thread.messages.map(\.body) == ["@grok hi", "Grok finished without replying."])
        #expect(thread.messages.last?.author == .notice)
        #expect(thread.cursors[.grok] == nil)

        model.draft = "again"
        model.send()
        try await waitUntilIdle(model)

        #expect(runner.prompts() == [
            "User: @grok hi",
            "User: @grok hi\nNotice: Grok finished without replying.\nUser: again",
        ])
        #expect(model.selectedThread?.cursors[.grok] == nil)
    }

    @Test func sendCreatesAPerThreadWorkspace() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let threads = directory.appending(path: "threads", directoryHint: .isDirectory)
        let workspaces = directory.appending(path: "workspaces", directoryHint: .isDirectory)
        let model = DeskModel(
            store: ThreadStore(directory: threads),
            runner: SilentRunner(),
            workspacesDirectory: workspaces
        )
        model.newThread()
        let id = try #require(model.selection)
        let workspace = workspaces.appending(path: id.uuidString, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: workspace.path(percentEncoded: false)) == false)
        model.draft = "hi"
        model.send()
        try await waitUntilIdle(model)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: workspace.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func newThreadIsSavedBeforeTheFirstSend() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DeskModel(store: ThreadStore(directory: directory), runner: SilentRunner())
        model.newThread()
        let id = try #require(model.selection)
        let loaded = try ThreadStore(directory: directory).load()
        let restored = try #require(loaded.first { $0.id == id })
        #expect(loaded.count == 1)
        #expect(restored.title == Thread.untitled)
        #expect(restored.messages.isEmpty)
    }

    @Test func renameAndDeleteRoundTrip() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DeskModel(store: ThreadStore(directory: directory), runner: RecordingRunner(), trash: { _ in })
        model.newThread()
        let id = try #require(model.selection)
        model.draft = "hello"
        model.send()
        try await waitUntilIdle(model)

        model.beginRename(id)
        model.renameText = "Renamed"
        model.commitRename()
        #expect(model.selectedThread?.title == "Renamed")

        var restored = try ThreadStore(directory: directory).load()
        #expect(restored.map(\.title) == ["Renamed"])

        model.delete(id)
        #expect(model.threads.isEmpty)
        #expect(model.selection == nil)
        restored = try ThreadStore(directory: directory).load()
        #expect(restored.isEmpty)
    }

    @Test func deleteMovesTheWorkspaceToTheTrash() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspaces = directory.appending(path: "workspaces", directoryHint: .isDirectory)
        let trashed = Mutex<[URL]>([])
        let model = DeskModel(
            store: ThreadStore(directory: directory.appending(path: "threads", directoryHint: .isDirectory)),
            runner: SilentRunner(),
            workspacesDirectory: workspaces,
            trash: { url in trashed.withLock { $0.append(url) } }
        )
        model.newThread()
        let id = try #require(model.selection)
        let workspace = workspaces.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        model.delete(id)

        #expect(trashed.withLock { $0 }.map(\.lastPathComponent) == [id.uuidString])
    }

    @Test func deletingTheRunningThreadTrashesItsWorkspaceAfterTheAgentExits() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let threads = directory.appending(path: "threads", directoryHint: .isDirectory)
        let workspaces = directory.appending(path: "workspaces", directoryHint: .isDirectory)
        let marker = directory.appending(path: "exited", directoryHint: .notDirectory)
        let markerPath = marker.path(percentEncoded: false)
        let script = directory.appending(path: "agent", directoryHint: .notDirectory)
        try Data(
            """
            #!/usr/bin/perl
            use Time::HiRes qw(time sleep);
            $| = 1;
            $SIG{TERM} = sub {
                my $end = time() + 0.4;
                while (time() < $end) { sleep(0.05); }
                open my $out, ">", $ENV{DESK_EXIT_MARKER} or exit 1;
                print $out "exited\\n";
                close $out;
                exit 0;
            };
            print "partial\\n";
            while (1) { sleep 60; }
            """.utf8
        ).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

        let trashed = Mutex<[URL]>([])
        let markerAtTrash = Mutex<String?>(nil)
        let model = DeskModel(
            store: ThreadStore(directory: threads),
            runner: ExitingAgentRunner(executable: script, markerPath: markerPath),
            workspacesDirectory: workspaces,
            trash: { url in
                let text = (try? String(contentsOfFile: markerPath, encoding: .utf8)) ?? ""
                trashed.withLock { $0.append(url) }
                markerAtTrash.withLock { $0 = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        )
        defer { model.stop() }
        model.newThread()
        let runningID = try #require(model.selection)
        let workspace = workspaces.appending(path: runningID.uuidString, directoryHint: .isDirectory)
        model.draft = "hi"
        model.send()

        var sawPartial = false
        for _ in 0..<500 {
            if model.threads.first(where: { $0.id == runningID })?.messages.contains(where: { $0.body.contains("partial") }) == true {
                sawPartial = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawPartial)
        try #require(sawPartial)

        model.newThread()
        let otherID = try #require(model.selection)
        #expect(otherID != runningID)
        #expect(model.isRunning)

        model.delete(runningID)

        #expect(model.selection == otherID)
        #expect(model.threads.map(\.id) == [otherID])
        #expect(try ThreadStore(directory: threads).load().map(\.id) == [otherID])
        #expect(FileManager.default.fileExists(atPath: workspace.path(percentEncoded: false)))
        #expect(trashed.withLock { $0 }.isEmpty)
        #expect(markerAtTrash.withLock { $0 } == nil)

        var markerValue: String?
        for _ in 0..<250 {
            markerValue = markerAtTrash.withLock { $0 }
            if markerValue != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(markerValue == "exited")
        #expect(trashed.withLock { $0 }.map(\.lastPathComponent) == [runningID.uuidString])
        try await waitUntilIdle(model)
    }

    @Test func missingSessionRetriesOnceWithTheFullTranscript() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ScriptedRunner(steps: [
            .reply("earlier", session: "old"),
            .missingSession,
            .reply("fresh", session: "new"),
        ])
        let model = DeskModel(store: ThreadStore(directory: directory), runner: runner)
        model.newThread()
        model.draft = "@grok hi"
        model.send()
        try await waitUntilIdle(model)

        model.draft = "again"
        model.send()
        try await waitUntilIdle(model)

        let notice = "Grok's earlier session wasn't found, so it started a new one with the full thread."
        let thread = try #require(model.selectedThread)
        #expect(thread.messages.map(\.body) == ["@grok hi", "earlier", "again", notice, "fresh"])
        #expect(thread.messages.map(\.author) == [.user, .agent(.grok), .user, .notice, .agent(.grok)])
        #expect(thread.sessions[.grok] == "new")
        #expect(thread.cursors[.grok] == 4)
        #expect(runner.calls() == [
            ScriptedRunner.Call(prompt: "User: @grok hi", session: nil),
            ScriptedRunner.Call(prompt: "User: again", session: "old"),
            ScriptedRunner.Call(
                prompt: "User: @grok hi\nGrok: earlier\nUser: again\nNotice: \(notice)",
                session: nil
            ),
        ])
    }

    @Test func missingSessionReportsASecondFailureWithoutRetryingAgain() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ScriptedRunner(steps: [
            .reply("earlier", session: "old"),
            .missingSession,
            .fail("still broken"),
        ])
        let model = DeskModel(store: ThreadStore(directory: directory), runner: runner, signInProbe: { _, _ in SignInOutput(stdout: "Logged in", exitCode: 0) })
        model.newThread()
        model.draft = "@grok hi"
        model.send()
        try await waitUntilIdle(model)

        model.draft = "again"
        model.send()
        try await waitUntilIdle(model)

        let thread = try #require(model.selectedThread)
        #expect(thread.messages.map(\.body) == [
            "@grok hi",
            "earlier",
            "again",
            "Grok's earlier session wasn't found, so it started a new one with the full thread.",
            "still broken",
        ])
        #expect(thread.sessions[.grok] == nil)
        #expect(thread.cursors[.grok] == 1)
        #expect(runner.calls().count == 3)
        #expect(runner.calls().last?.session == nil)
        #expect(runner.calls().last?.prompt.hasPrefix("User: @grok hi\nGrok: earlier\nUser: again\nNotice:") == true)
    }

    @Test func missingSessionAfterTextDoesNotRetry() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ScriptedRunner(steps: [
            .reply("earlier", session: "old"),
            .textThenMissing("partial"),
        ])
        let model = DeskModel(store: ThreadStore(directory: directory), runner: runner, signInProbe: { _, _ in SignInOutput(stdout: "Logged in", exitCode: 0) })
        model.newThread()
        model.draft = "@grok hi"
        model.send()
        try await waitUntilIdle(model)

        model.draft = "again"
        model.send()
        try await waitUntilIdle(model)

        let thread = try #require(model.selectedThread)
        #expect(thread.messages.map(\.body) == ["@grok hi", "earlier", "again", "partial", "missing"])
        #expect(thread.messages.map(\.author) == [.user, .agent(.grok), .user, .agent(.grok), .notice])
        #expect(thread.sessions[.grok] == "old")
        #expect(runner.calls().count == 2)
    }

    @Test func deleteIgnoresAMissingWorkspace() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trashed = Mutex<[URL]>([])
        let model = DeskModel(
            store: ThreadStore(directory: directory),
            runner: SilentRunner(),
            workspacesDirectory: directory.appending(path: "workspaces", directoryHint: .isDirectory),
            trash: { url in trashed.withLock { $0.append(url) } }
        )
        model.newThread()

        model.delete(try #require(model.selection))

        #expect(model.threads.isEmpty)
        #expect(trashed.withLock { $0 }.isEmpty)
    }

    @Test func launchSelectsTheMostRecentThread() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let older = Thread(title: "Older", updatedAt: .now.addingTimeInterval(-3600))
        let newer = Thread(title: "Newer", updatedAt: .now)
        try store.save(older)
        try store.save(newer)

        let model = DeskModel(store: store, runner: SilentRunner())

        #expect(model.selection == newer.id)
    }

    @Test func newThreadReusesAnEmptyThread() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DeskModel(store: ThreadStore(directory: directory), runner: SilentRunner())

        model.newThread()
        let first = model.selection
        model.newThread()

        #expect(model.threads.count == 1)
        #expect(model.selection == first)
    }

    @Test func aFailedSaveIsReportedUntilASaveSucceeds() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file in the threads directory's parent path makes every save fail.
        let blocked = directory.appending(path: "blocked", directoryHint: .notDirectory)
        try Data().write(to: blocked)
        let threads = blocked.appending(path: "threads", directoryHint: .isDirectory)
        let model = DeskModel(store: ThreadStore(directory: threads), runner: SilentRunner())

        model.newThread()
        #expect(model.saveError?.hasPrefix("Couldn't save") == true)

        try FileManager.default.removeItem(at: blocked)
        model.retrySave()
        #expect(model.saveError == nil)
    }

    @Test func aFailedLoadIsReportedAndRetried() throws {
        let directory = try makeTempDirectory()
        let threads = directory.appending(path: "threads", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: threads.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }
        try ThreadStore(directory: threads).save(Thread(title: "Kept"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: threads.path(percentEncoded: false))

        let model = DeskModel(store: ThreadStore(directory: threads), runner: SilentRunner())
        #expect(model.threads.isEmpty)
        #expect(model.saveError?.hasPrefix("Couldn't read your saved threads") == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: threads.path(percentEncoded: false))
        model.retrySave()
        #expect(model.saveError == nil)
        #expect(model.threads.map(\.title) == ["Kept"])
    }

    @Test func aThreadWhoseFileCannotBeDeletedStays() throws {
        let directory = try makeTempDirectory()
        let threads = directory.appending(path: "threads", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: threads.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: directory)
        }
        let model = DeskModel(store: ThreadStore(directory: threads), runner: SilentRunner(), trash: { _ in })
        model.newThread()
        let id = try #require(model.selection)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: threads.path(percentEncoded: false))

        model.delete(id)

        #expect(model.threads.map(\.id) == [id])
        #expect(model.selection == id)
        #expect(model.saveError?.hasPrefix("Couldn't delete") == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: threads.path(percentEncoded: false))
        model.retrySave()
        #expect(model.threads.isEmpty)
        #expect(model.saveError == nil)
        #expect(try ThreadStore(directory: threads).load().isEmpty)
    }

    @Test func selectedModelIsStoredPerAgent() throws {
        let name = "desk-model-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DeskModel(store: ThreadStore(directory: directory), runner: SilentRunner(), defaults: defaults)
        #expect(model.selectedModel(for: .claude) == nil)
        model.setSelectedModel("claude-opus-5-5", for: .claude)
        model.setSelectedModel("grok-4", for: .grok)
        #expect(defaults.string(forKey: "model.claude") == "claude-opus-5-5")
        #expect(defaults.string(forKey: "model.grok") == "grok-4")
        #expect(model.selectedModel(for: .claude) == "claude-opus-5-5")

        let again = DeskModel(store: ThreadStore(directory: directory), runner: SilentRunner(), defaults: defaults)
        #expect(again.selectedModel(for: .claude) == "claude-opus-5-5")
        #expect(again.selectedModel(for: .grok) == "grok-4")
        #expect(again.selectedModel(for: .muse) == nil)

        again.setSelectedModel(nil, for: .claude)
        again.setSelectedModel("", for: .grok)
        #expect(defaults.string(forKey: "model.claude") == nil)
        #expect(defaults.string(forKey: "model.grok") == nil)
        #expect(again.selectedModel(for: .claude) == nil)
        #expect(again.selectedModel(for: .grok) == nil)
        // The choice lives in observable state, so pickers and labels redraw when it changes.
        #expect(again.selectedModels.isEmpty)
        #expect(model.selectedModels[.claude] == "claude-opus-5-5")
    }

    @Test func replyUsesTheReportedModelOrTheSelection() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "desk-reply-model-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        defer { suite.removePersistentDomain(forName: name) }

        let runner = RecordingRunner()
        let model = DeskModel(store: ThreadStore(directory: directory), runner: runner, defaults: suite)
        model.setSelectedModel("claude-sonnet-5-5", for: .claude)
        model.newThread()
        model.draft = "hi"
        model.send()
        try await waitUntilIdle(model)

        let selected = try #require(model.selectedThread?.messages.last)
        #expect(selected.model == "claude-sonnet-5-5")
        #expect(runner.models() == ["claude-sonnet-5-5"])

        let reported = DeskModel(
            store: ThreadStore(directory: directory),
            runner: ModelEventRunner(),
            defaults: suite
        )
        reported.newThread()
        reported.setSelectedModel("claude-sonnet-5-5", for: .claude)
        reported.draft = "hi"
        reported.send()
        try await waitUntilIdle(reported)
        #expect(reported.selectedThread?.messages.last?.model == "grok-4.7")
    }

    @Test func activityShowsWhileTheAgentWorksAndClearsWhenTextArrives() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DeskModel(store: ThreadStore(directory: directory), runner: ActivityRunner())
        model.newThread()
        model.draft = "hi"
        model.send()

        var sawThinking = false
        for _ in 0..<100 {
            if model.activity == "Thinking" {
                sawThinking = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawThinking)
        try await waitUntilIdle(model)
        #expect(model.activity == nil)
        #expect(model.selectedThread?.messages.last?.body == "hi")
    }
}

private final class RecordingRunner: AgentRunner, Sendable {
    private struct State: Sendable {
        var prompts: [(AgentID, String)] = []
        var sessions: [String?] = []
        var models: [String?] = []
    }

    private let state = Mutex<State>(.init())

    func run(agent: AgentID, prompt: String, session: String?, workspace _: URL, model: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        state.withLock { state in
            state.prompts.append((agent, prompt))
            state.sessions.append(session)
            state.models.append(model)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("hello"))
            continuation.yield(.session("sess-\(agent.rawValue)"))
            continuation.finish()
        }
    }

    func prompts() -> [(AgentID, String)] {
        state.withLock { $0.prompts }
    }

    func sessions() -> [String?] {
        state.withLock { $0.sessions }
    }

    func models() -> [String?] {
        state.withLock { $0.models }
    }
}

private final class SilentRunner: AgentRunner, Sendable {
    private let recorded = Mutex<[String]>([])

    func run(agent _: AgentID, prompt: String, session _: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        recorded.withLock { $0.append(prompt) }
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func prompts() -> [String] {
        recorded.withLock { $0 }
    }
}

private final class ScriptedRunner: AgentRunner, Sendable {
    struct Call: Equatable, Sendable {
        var prompt: String
        var session: String?
    }

    enum Step: Sendable {
        case reply(String, session: String)
        case missingSession
        case fail(String)
        case textThenMissing(String)
    }

    private let steps: Mutex<[Step]>
    private let recorded = Mutex<[Call]>([])

    init(steps: [Step]) {
        self.steps = Mutex(steps)
    }

    func run(agent _: AgentID, prompt: String, session: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        let step = steps.withLock { steps -> Step? in
            guard !steps.isEmpty else { return nil }
            return steps.removeFirst()
        }
        recorded.withLock { $0.append(Call(prompt: prompt, session: session)) }
        return AsyncThrowingStream { continuation in
            switch step {
            case .reply(let text, let session):
                continuation.yield(.text(text))
                continuation.yield(.session(session))
                continuation.finish()
            case .missingSession:
                continuation.finish(throwing: AgentRunError(message: "missing", missingSession: true))
            case .fail(let message):
                continuation.finish(throwing: AgentRunError(message: message))
            case .textThenMissing(let text):
                continuation.yield(.text(text))
                continuation.finish(throwing: AgentRunError(message: "missing", missingSession: true))
            case nil:
                continuation.finish(throwing: AgentRunError(message: "unexpected run"))
            }
        }
    }

    func calls() -> [Call] {
        recorded.withLock { $0 }
    }
}

private struct ExitingAgentRunner: AgentRunner {
    var executable: URL
    var markerPath: String

    func run(agent _: AgentID, prompt _: String, session _: String?, workspace: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        var environment = AgentCommand.environment()
        environment["DESK_EXIT_MARKER"] = markerPath
        return AgentProcess(
            label: "stand-in",
            executable: executable,
            candidates: [],
            arguments: [],
            environment: environment,
            workspace: workspace,
            notFound: "stand-in was not found."
        ).run { YieldingParser() }
    }
}

private struct YieldingParser: AgentLineParser {
    var finishedCleanly: Bool { false }

    mutating func events(from line: String) throws -> [AgentEvent] {
        [.text(line)]
    }
}

private struct ModelEventRunner: AgentRunner {
    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.model("grok-4.7"))
            continuation.yield(.text("hello"))
            continuation.finish()
        }
    }
}

private struct ActivityRunner: AgentRunner {
    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.activity("Thinking"))
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    continuation.yield(.text("hi"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private struct HangingRunner: AgentRunner {
    func run(agent: AgentID, prompt: String, session _: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.text("partial-\(agent.rawValue)"))
                do {
                    try await Task.sleep(for: .seconds(30))
                    continuation.yield(.text("-done"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

@MainActor
private func waitUntilIdle(_ model: DeskModel) async throws {
    for _ in 0..<200 {
        if !model.isRunning { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the turn to finish")
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-model-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
