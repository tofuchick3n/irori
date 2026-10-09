import Foundation
import Testing
@testable import Desk

@Test func workspaceDirectoryLivesBesideThreads() throws {
    let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    var path = ThreadStore.workspaceDirectory(for: id).path(percentEncoded: false)
    if path.hasSuffix("/") {
        path.removeLast()
    }
    #expect(path.hasSuffix("/Library/Application Support/\(Brand.supportFolder)/workspaces/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
}

@Test func applicationSupportDirectoryMatchesTheDeskThreadsFolder() {
    var path = ThreadStore.applicationSupportDirectory.path(percentEncoded: false)
    if path.hasSuffix("/") {
        path.removeLast()
    }
    #expect(path.hasSuffix("/Library/Application Support/\(Brand.supportFolder)/threads"))
}

@Test func loadSkipsUnreadableFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-unreadable-\(UUID().uuidString)", directoryHint: .isDirectory)
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let hidden = Thread(title: "Hidden", createdAt: created, updatedAt: created)
    let hiddenPath = directory
        .appending(path: "\(hidden.id.uuidString).json", directoryHint: .notDirectory)
        .path(percentEncoded: false)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hiddenPath)
        try? FileManager.default.removeItem(at: directory)
    }

    let store = ThreadStore(directory: directory)
    let visible = Thread(
        title: "Visible",
        createdAt: created,
        updatedAt: created,
        messages: [Message(author: .user, body: "hello", createdAt: created)]
    )
    try store.save(visible)
    try store.save(hidden)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hiddenPath)

    let loaded = try store.load()
    #expect(loaded.map(\.id) == [visible.id])
}

@Test func missingDirectoryLoadsAsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = ThreadStore(directory: directory)
    #expect(try store.load().isEmpty)
}

@Test func saveLoadRoundTripAndDelete() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ThreadStore(directory: directory)
    let created = Date(timeIntervalSince1970: 1_700_000_000.125)
    let first = Thread(
        title: "Hello",
        createdAt: created,
        updatedAt: created,
        messages: [
            Message(author: .user, body: "@grok @claude hi", createdAt: created),
            Message(author: .agent(.grok), body: "heard", createdAt: created),
        ],
        cursors: [.grok: 1],
        sessions: [.claude: "sess-1"]
    )
    let second = Thread(
        title: "Other",
        createdAt: created.addingTimeInterval(2),
        updatedAt: created.addingTimeInterval(2),
        messages: [Message(author: .user, body: "just claude", createdAt: created)]
    )

    try store.save(first)
    try store.save(second)

    let file = directory.appending(path: "\(first.id.uuidString).json", directoryHint: .notDirectory)
    #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

    let loaded = try store.load()
    #expect(loaded.count == 2)
    let restored = try #require(loaded.first { $0.id == first.id })
    #expect(restored.title == first.title)
    #expect(restored.messages.map(\.body) == first.messages.map(\.body))
    #expect(restored.messages.map(\.author) == first.messages.map(\.author))
    #expect(restored.messages.map(\.id) == first.messages.map(\.id))
    #expect(restored.cursors == [.grok: 1])
    #expect(restored.sessions == [.claude: "sess-1"])
    #expect(abs(restored.createdAt.timeIntervalSince(first.createdAt)) < 0.001)
    #expect(abs(restored.updatedAt.timeIntervalSince(first.updatedAt)) < 0.001)
    #expect(abs(restored.messages[0].createdAt.timeIntervalSince(created)) < 0.001)

    try store.delete(id: first.id)
    #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) == false)
    let remaining = try store.load()
    #expect(remaining.map(\.id) == [second.id])
    try store.delete(id: first.id)
}
