import Foundation
import Testing
@testable import Desk

@Test func findIgnoresCaseAndDiacriticsAndDoesNotOverlap() {
    #expect(TranscriptFind.ranges(of: "cafe", in: "Café and CAFE") == [NSRange(location: 0, length: 4), NSRange(location: 9, length: 4)])
    #expect(TranscriptFind.ranges(of: "aa", in: "aaaa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    #expect(TranscriptFind.ranges(of: "  ", in: "a  b").isEmpty)
    #expect(TranscriptFind.ranges(of: "x", in: "").isEmpty)
}

@MainActor
@Test func findSearchesRenderedTextAndSkipsNotices() {
    let user = Message(author: .user, body: "Plan the **launch** today")
    let notice = Message(author: .notice, body: "launch notice")
    let reply = Message(author: .agent(.claude), body: "`launch` it")
    let matches = TranscriptFind.matches(in: [user, notice, reply], query: "launch today")
    #expect(matches == [FindMatch(messageID: user.id, range: NSRange(location: 9, length: 12))])

    let all = TranscriptFind.matches(in: [user, notice, reply], query: "LAUNCH")
    #expect(all.map(\.messageID) == [user.id, reply.id])
    #expect(all[1].range == NSRange(location: 0, length: 6))
}

@MainActor
@Test func findStartsAtTheNewestMatchAndWraps() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-find-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-find-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = Thread(messages: [
        Message(author: .user, body: "one idea"),
        Message(author: .agent(.claude), body: "another idea"),
        Message(author: .user, body: "last idea"),
    ])
    let store = ThreadStore(directory: directory)
    try store.save(first)
    try store.save(Thread(messages: [Message(author: .user, body: "nothing here")]))
    let model = DeskModel(store: store, runner: EchoAgentRunner(), trash: { _ in }, defaults: defaults)
    model.selection = first.id

    #expect(model.findMatches.isEmpty)
    model.beginFind()
    model.findQuery = "idea"
    #expect(model.findMatches.count == 3)
    #expect(model.currentFindIndex(among: 3) == 2)
    model.moveFind(1)
    #expect(model.currentFindIndex(among: 3) == 0)
    model.moveFind(-1)
    model.moveFind(-1)
    #expect(model.currentFindIndex(among: 3) == 1)

    model.findQuery = "idea "
    #expect(model.findIndex == nil)
    model.moveFind(-1)
    model.selection = model.threads.first { $0.id != first.id }?.id
    #expect(model.findIndex == nil)
    #expect(model.findMatches.isEmpty)
    #expect(model.currentFindIndex(among: 0) == nil)

    model.endFind()
    #expect(!model.isFinding)
}

@MainActor
@Test func escapeClosesFindThenTheFilesDrawer() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-find-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = DeskModel(store: ThreadStore(directory: directory), trash: { _ in }, defaults: try #require(UserDefaults(suiteName: "desk-find-\(UUID().uuidString)")))
    model.showsFiles = true
    model.beginFind()

    #expect(model.dismissForEscape())
    #expect(!model.isFinding)
    #expect(model.showsFiles)
    #expect(model.dismissForEscape())
    #expect(!model.showsFiles)
    #expect(!model.dismissForEscape())
}
