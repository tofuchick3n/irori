import AppKit
import Foundation
import Synchronization
import Testing
@testable import Desk

@Test func anOldThreadFileWithoutTagsDecodesAsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-old-tags-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ThreadStore(directory: directory)
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let thread = Thread(
        title: "Old",
        createdAt: created,
        updatedAt: created,
        messages: [Message(author: .agent(.claude), body: "hi", createdAt: created, effort: "high")],
        tags: ["Initech"]
    )
    try store.save(thread)
    let url = directory.appending(path: "\(thread.id.uuidString).json")
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    var object = try #require(saved)
    object.removeValue(forKey: "tags")
    var messages = try #require(object["messages"] as? [[String: Any]])
    messages[0].removeValue(forKey: "effort")
    object["messages"] = messages
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)

    let loaded = try #require(try store.load().first)
    #expect(loaded.tags == [])
    #expect(loaded.messages.first?.effort == nil)
    #expect(loaded.messages.first?.body == "hi")
    #expect(loaded.title == "Old")
}

@Test @MainActor func tagsDedupeAndReuseAKnownOrExistingSpelling() throws {
    let directory = try makeTagDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, defaultsName) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let model = DeskModel(store: ThreadStore(directory: directory), runner: IdleTagRunner(), defaults: defaults)
    model.newThread()
    let id = try #require(model.selection)

    model.addTag(named: "  acme corp  ", to: id)
    model.addTag(named: "ACME CORP", to: id)
    model.addTag(named: "   ", to: id)
    model.addTag(named: "", to: id)
    #expect(model.selectedThread?.tags == ["acme corp"])

    model.addTag(named: "acme", to: id)
    model.addTag(named: "ACME", to: id)
    #expect(model.selectedThread?.tags == ["acme corp", "acme"])

    model.toggleTag("Acme Corp", on: id)
    #expect(model.selectedThread?.tags == ["acme"])
    model.toggleTag("acme", on: id)
    #expect(model.selectedThread?.tags == [])
    model.toggleTag("  ", on: id)
    model.toggleTag("globex", on: id)
    #expect(model.selectedThread?.tags == ["globex"])
    let kept = try #require(try ThreadStore(directory: directory).load().first { $0.id == id })
    #expect(kept.tags == ["globex"])

    let extraDirectory = try makeTagDirectory()
    defer { try? FileManager.default.removeItem(at: extraDirectory) }
    let carrier = Thread(title: "Carrier", messages: [Message(author: .user, body: "hi")], tags: ["acme"])
    let blank = Thread(title: "Blank", messages: [Message(author: .user, body: "yo")])
    let extra = ThreadStore(directory: extraDirectory)
    try extra.save(carrier)
    try extra.save(blank)
    let (secondDefaults, secondDefaultsName) = try isolatedDefaults()
    defer { secondDefaults.removePersistentDomain(forName: secondDefaultsName) }
    let second = DeskModel(store: extra, runner: IdleTagRunner(), defaults: secondDefaults)
    second.addTag(named: "ACME", to: blank.id)
    second.addTag(named: "acme", to: blank.id)
    #expect(second.threads.first { $0.id == blank.id }?.tags == ["acme"])
}

@Test @MainActor func theSidebarFilterHidesOtherClientsAndSurvivesRelaunch() throws {
    let name = "desk-tags-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }
    let directory = try makeTagDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ThreadStore(directory: directory)
    let older = Thread(title: "Older", updatedAt: Date(timeIntervalSince1970: 10), tags: ["Initech"])
    let newer = Thread(title: "Newer", updatedAt: Date(timeIntervalSince1970: 20), tags: ["Initech", "acme"])
    let other = Thread(title: "Other", updatedAt: Date(timeIntervalSince1970: 30), tags: ["Globex"])
    try store.save(older)
    try store.save(newer)
    try store.save(other)

    let model = DeskModel(store: store, runner: IdleTagRunner(), defaults: defaults)
    #expect(model.visibleThreads.map(\.id) == model.orderedThreads.map(\.id))
    #expect(model.allTags == ["acme", "Globex", "Initech"])

    model.tagFilter = " Initech "
    #expect(model.tagFilter == "Initech")
    #expect(model.visibleThreads.map(\.title) == ["Newer", "Older"])
    #expect(defaults.string(forKey: "sidebar.tagFilter") == "Initech")

    let again = DeskModel(store: store, runner: IdleTagRunner(), defaults: defaults)
    #expect(again.tagFilter == "Initech")
    #expect(again.visibleThreads.map(\.title) == ["Newer", "Older"])
    again.tagFilter = nil
    #expect(defaults.string(forKey: "sidebar.tagFilter") == nil)
    let third = DeskModel(store: store, runner: IdleTagRunner(), defaults: defaults)
    #expect(third.tagFilter == nil)
    #expect(third.visibleThreads.map(\.title) == ["Other", "Newer", "Older"])
}

@Test @MainActor func newThreadInheritsTheClientFilterIncludingAReusedEmptyThread() throws {
    let directory = try makeTagDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (defaults, defaultsName) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let model = DeskModel(store: ThreadStore(directory: directory), runner: IdleTagRunner(), defaults: defaults)
    model.tagFilter = "Takibi Base"
    model.newThread()
    let created = try #require(model.selection)
    #expect(model.selectedThread?.tags == ["Takibi Base"])
    model.newThread()
    #expect(model.selection == created)
    #expect(model.threads.count == 1)
    #expect(model.selectedThread?.tags == ["Takibi Base"])

    let empty = Thread(title: Thread.untitled)
    let reuseDirectory = try makeTagDirectory()
    defer { try? FileManager.default.removeItem(at: reuseDirectory) }
    try ThreadStore(directory: reuseDirectory).save(empty)
    let (reuseDefaults, reuseDefaultsName) = try isolatedDefaults()
    defer { reuseDefaults.removePersistentDomain(forName: reuseDefaultsName) }
    let reused = DeskModel(store: ThreadStore(directory: reuseDirectory), runner: IdleTagRunner(), defaults: reuseDefaults)
    reused.tagFilter = "initech"
    reused.newThread()
    #expect(reused.threads.count == 1)
    #expect(reused.selection == empty.id)
    #expect(reused.selectedThread?.tags == ["initech"])
}

@Test @MainActor func aFailedTagSaveShowsUpAsASaveError() throws {
    let directory = try makeTagDirectory()
    let threads = directory.appending(path: "threads", directoryHint: .isDirectory)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: threads.path(percentEncoded: false))
        try? FileManager.default.removeItem(at: directory)
    }
    let (defaults, defaultsName) = try isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let model = DeskModel(store: ThreadStore(directory: threads), runner: IdleTagRunner(), defaults: defaults)
    model.newThread()
    let id = try #require(model.selection)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: threads.path(percentEncoded: false))

    model.toggleTag("Initech", on: id)

    #expect(model.selectedThread?.tags == ["Initech"])
    #expect(model.saveError?.hasPrefix("Couldn't save") == true)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: threads.path(percentEncoded: false))
    model.retrySave()
    #expect(model.saveError == nil)
    let loaded = try #require(try ThreadStore(directory: threads).load().first)
    #expect(loaded.tags == ["Initech"])
}

@Test func supportDirectoryLivesInApplicationSupport() {
    var path = ThreadStore.supportDirectory.path(percentEncoded: false)
    if path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    #expect(path.hasSuffix("/Library/Application Support/\(Brand.supportFolder)"))
    #expect(TagLibrary.slug("Blue Sky") == "blue-sky")
    #expect(TagLibrary.slug("Example") == "example")
    #expect(TagLibrary.slug(" Jane Doe ") == "jane-doe")
}

private func isolatedDefaults() throws -> (UserDefaults, String) {
    let name = "desk-tags-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
}

private func makeTagDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-tags-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private struct IdleTagRunner: AgentRunner {
    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@MainActor
@Test func newThreadDoesNotReuseAnotherClientsEmptyThread() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-tags-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-tags-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ThreadStore(directory: directory)
    let globex = Thread(title: "Globex draft", tags: ["Globex"])
    try store.save(globex)

    let model = DeskModel(store: store, runner: EchoAgentRunner(), trash: { _ in }, defaults: defaults)
    model.tagFilter = "Initech"
    model.newThread()

    #expect(model.threads.count == 2)
    #expect(model.threads.first { $0.id == globex.id }?.tags == ["Globex"])
    #expect(model.selectedThread?.tags == ["Initech"])
}

@MainActor
@Test func filteringMovesTheSelectionToAVisibleThread() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-tags-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-tags-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ThreadStore(directory: directory)
    let initech = Thread(title: "Initech", updatedAt: .now.addingTimeInterval(-60), tags: ["Initech"])
    let globex = Thread(title: "Globex", updatedAt: .now, tags: ["Globex"])
    try store.save(initech)
    try store.save(globex)

    let model = DeskModel(store: store, runner: EchoAgentRunner(), trash: { _ in }, defaults: defaults)
    #expect(model.selection == globex.id)
    model.tagFilter = "Initech"
    #expect(model.selection == initech.id)
    model.tagFilter = "Hooli"
    #expect(model.selection == nil)

    let relaunched = DeskModel(store: store, runner: EchoAgentRunner(), trash: { _ in }, defaults: defaults)
    #expect(relaunched.tagFilter == "Hooli")
    #expect(relaunched.selection == nil)
}

@MainActor
@Test func tagsCreateRenameDeleteAndLogosStayInTheSupportFolder() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-tags-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appending(path: "support", directoryHint: .isDirectory)
    let threads = root.appending(path: "threads", directoryHint: .isDirectory)
    let suite = "desk-tags-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let trashed = Mutex<[URL]>([])
    let model = DeskModel(
        store: ThreadStore(directory: threads),
        runner: IdleTagRunner(),
        trash: { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        },
        defaults: defaults,
        supportDirectory: support
    )

    model.createTag("  Initech  ")
    model.createTag("initech")
    model.createTag("   ")
    #expect(model.allTags == ["Initech"])
    model.newThread()
    let threadID = try #require(model.selection)
    model.addTag(named: "initech", to: threadID)
    #expect(model.selectedThread?.tags == ["Initech"])

    let png = root.appending(path: "logo.png")
    try writePNG(width: 16, height: 16, to: png)
    try model.setLogo(for: "Initech", from: png)
    let initechLogo = TagLibrary.logoURL("Initech", in: support)
    #expect(FileManager.default.fileExists(atPath: initechLogo.path(percentEncoded: false)))
    let cached = model.logo(for: "Initech")
    #expect(cached != nil)
    #expect(model.logo(for: "Initech") === cached)
    #expect(model.logo(for: "missing") == nil)
    #expect(throws: DeskImageError.self) {
        try model.setLogo(for: "Initech", from: root.appending(path: "nope.txt"))
    }

    model.renameTag("initech", to: "Acme Corp")
    #expect(model.selectedThread?.tags == ["Acme Corp"])
    #expect(TagLibrary.load(from: support) == ["Acme Corp"])
    #expect(!FileManager.default.fileExists(atPath: initechLogo.path(percentEncoded: false)))
    let moved = TagLibrary.logoURL("Acme Corp", in: support)
    #expect(FileManager.default.fileExists(atPath: moved.path(percentEncoded: false)))
    #expect(model.logo(for: "Acme Corp") != nil)
    #expect(model.logo(for: "Initech") == nil)
    let stored = try ThreadStore(directory: threads).load()
    #expect(stored.first?.tags == ["Acme Corp"])

    model.tagFilter = "Acme Corp"
    model.deleteTag("acme corp")
    #expect(model.tagFilter == nil)
    #expect(defaults.object(forKey: "sidebar.tagFilter") == nil)
    #expect(model.selectedThread?.tags.isEmpty == true)
    #expect(model.allTags.isEmpty)
    #expect(TagLibrary.load(from: support).isEmpty)
    #expect(model.logo(for: "Acme Corp") == nil)
    #expect(trashed.withLock { $0 } == [moved])
    #expect(!FileManager.default.fileExists(atPath: moved.path(percentEncoded: false)))

    model.createTag("Initech")
    let remembered = DeskModel(
        store: ThreadStore(directory: threads),
        runner: IdleTagRunner(),
        trash: { _ in },
        defaults: defaults,
        supportDirectory: support
    )
    #expect(remembered.allTags == ["Initech"])
    remembered.tagFilter = "initech"
    remembered.newThread()
    #expect(remembered.selectedThread?.tags == ["Initech"])

    try remembered.setLogo(for: "Initech", from: png)
    #expect(remembered.logo(for: "Initech") != nil)
    remembered.removeLogo(for: "Initech")
    #expect(remembered.logo(for: "Initech") == nil)
    #expect(!FileManager.default.fileExists(atPath: TagLibrary.logoURL("Initech", in: support).path(percentEncoded: false)))
}

@MainActor
@Test func tagsThatWouldShareALogoFileAreOneTag() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-slug-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-slug-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = DeskModel(
        store: ThreadStore(directory: directory.appending(path: "threads", directoryHint: .isDirectory)),
        runner: EchoAgentRunner(),
        trash: { _ in },
        defaults: defaults,
        supportDirectory: directory
    )
    model.createTag("Acme Corp")
    model.createTag("acme-corp")
    #expect(model.allTags == ["Acme Corp"])
}

@Test func tagSlugsCanNeverLeaveTheClientsFolder() {
    let support = URL(filePath: "/tmp/desk-support", directoryHint: .isDirectory)
    let clients = TagLibrary.clientsDirectory(in: support).standardizedFileURL.path(percentEncoded: false)
    for name in ["../../evil", "a/b", "..", "/etc/passwd", "...", "  ", "Acme Corp", "Takibi Base", "Example"] {
        let logo = TagLibrary.logoURL(name, in: support).standardizedFileURL
        #expect(logo.deletingLastPathComponent().path(percentEncoded: false) == clients, "\(name) escaped to \(logo.path)")
    }
    // Existing logo files keep their names.
    #expect(TagLibrary.slug("Acme Corp") == "acme-corp")
    #expect(TagLibrary.slug("Takibi Base") == "takibi-base")
    #expect(TagLibrary.slug("Example") == "example")
    #expect(TagLibrary.slug("../../evil") == "evil")
}

@MainActor
@Test func untaggingTheOpenThreadUnderAFilterMovesTheSelection() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-untag-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "desk-untag-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ThreadStore(directory: directory)
    let first = Thread(title: "First", updatedAt: .now, tags: ["Initech"])
    let second = Thread(title: "Second", updatedAt: .now.addingTimeInterval(-60), tags: ["Initech"])
    try store.save(first)
    try store.save(second)
    let model = DeskModel(store: store, runner: EchoAgentRunner(), trash: { _ in }, defaults: defaults)
    model.tagFilter = "Initech"
    #expect(model.selection == first.id)

    model.toggleTag("Initech", on: first.id)

    #expect(model.selection == second.id)
}
