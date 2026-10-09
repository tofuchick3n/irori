import Foundation
import Testing
@testable import Desk

@MainActor
struct ArchiveAndFilesTests {
    private func makeModel() throws -> (DeskModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "desk-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "desk-archive-\(UUID().uuidString)"))
        return (DeskModel(store: ThreadStore(directory: directory), runner: EchoAgentRunner(wordDelay: .zero), trash: { _ in }, defaults: defaults), directory)
    }

    @Test func archivingMovesAThreadOutOfTheListAndBack() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        let keep = try #require(model.selection)
        model.draft = "keep me"
        model.send()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        model.newThread()
        let archived = try #require(model.selection)
        model.draft = "archive me"
        model.send()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }

        model.archive(archived)
        #expect(!model.visibleThreads.contains { $0.id == archived })
        #expect(model.selection == keep)
        #expect(model.archivedCount == 1)

        model.showsArchived = true
        #expect(model.visibleThreads.map(\.id) == [archived])
        #expect(model.selection == archived)

        model.unarchive(archived)
        #expect(!model.showsArchived)
        #expect(model.visibleThreads.contains { $0.id == archived })
        #expect(model.selection == archived)

        // It survives a relaunch.
        model.archive(archived)
        let reloaded = try ThreadStore(directory: directory).load()
        #expect(reloaded.first { $0.id == archived }?.archivedAt != nil)
    }

    @Test func replyingInAnArchivedThreadUnarchivesIt() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        let id = try #require(model.selection)
        model.draft = "hi"
        model.send()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        model.archive(id)
        model.showsArchived = true
        model.selection = id
        model.draft = "back again"
        model.send()
        #expect(!model.showsArchived)
        #expect(model.selection == id)
        #expect(model.selectedThread?.archivedAt == nil)
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aReplyingThreadCantBeArchived() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.newThread()
        let id = try #require(model.selection)
        model.draft = "a long enough message to keep the echo going"
        model.send()
        model.archive(id)
        #expect(model.selectedThread?.archivedAt == nil)
        model.stop()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func newThreadLeavesTheArchivedView() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.showsArchived = true
        model.newThread()
        #expect(!model.showsArchived)
        #expect(model.selectedThread?.archivedAt == nil)
    }

    @Test func threadsWithoutArchivedAtStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","createdAt":0,"updatedAt":0,"messages":[],"cursors":[],"sessions":[]}"#
        let thread = try JSONDecoder().decode(Desk.Thread.self, from: Data(json.utf8))
        #expect(thread.archivedAt == nil)
    }

    @Test func filesAreListedNewestFirstWithTheirAgent() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "desk-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "out"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "a".write(to: folder.appending(path: "old.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: folder.appending(path: "old.md").path(percentEncoded: false))
        try "b".write(to: folder.appending(path: "out/report.html"), atomically: true, encoding: .utf8)
        try "c".write(to: folder.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        var reply = Message(author: .agent(.grok), body: "done")
        reply.files = ["out/report.html"]
        let thread = Desk.Thread(messages: [reply])

        let files = ThreadFile.list(in: folder, thread: thread)
        #expect(files.map(\.path) == ["out/report.html", "old.md"])
        #expect(files.first?.agent == .grok)
        #expect(files.last?.agent == nil)
    }
}
