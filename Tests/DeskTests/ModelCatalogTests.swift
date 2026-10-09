import Foundation
import Testing
@testable import Desk

@Test func claudeModelsAreStaticAndOpusIsTheDefault() {
    #expect(ModelLists.claude.map(\.id) == [
        "claude-opus-5-5",
        "claude-sonnet-5-5",
        "claude-fable-5-1",
        "claude-haiku-4-5-20251001",
    ])
    #expect(ModelLists.claude.map(\.label) == ["Opus 5.5", "Sonnet 5.5", "Fable 5.1", "Haiku 4.5"])
    #expect(ModelLists.claude.map(\.isDefault) == [true, false, false, false])
}

@Test func tidyModelIDsDropADateAndJoinTheTrailingVersion() {
    #expect(ModelLists.tidy("claude-haiku-4-5-20251001") == "Claude Haiku 4.5")
    #expect(ModelLists.tidy("claude-opus-5-5") == "Claude Opus 5.5")
    #expect(ModelLists.tidy("grok-4") == "Grok 4")
}

@Test @MainActor func catalogLabelWinsOverTheTidyId() {
    let catalog = ModelCatalog()
    #expect(catalog.label(for: "claude-opus-5-5", agent: .claude) == "Opus 5.5")
    #expect(catalog.label(for: "claude-haiku-4-5-20251001", agent: .codex) == "Claude Haiku 4.5")
}

@Test func grokModelLinesMarkTheStarAsDefault() {
    let text = """
    Models
      * grok-4 (default)
      - grok-3
      - grok-4
    *stuck
    plain
    """
    #expect(ModelLists.parseGrokModels(text) == [
        AgentModelOption(id: "grok-4", label: "Grok 4", isDefault: true),
        AgentModelOption(id: "grok-3", label: "Grok 3", isDefault: false),
    ])
}

@Test func museCatalogParsesRowsFromATempDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-muse-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data(#"{"rows":[{"model_id":"muse-b","display_label":"later"}]}"#.utf8)
        .write(to: directory.appending(path: "b.json"))
    try Data(#"{"rows":[{"model_id":"muse-a","display_label":"","visibility":"visible","is_default":true},{"model_id":"muse-hidden","visibility":"hidden"},{"model_id":"","display_label":"nope"},{"model_id":"muse-b","display_label":"Bee","is_default":false}]}"#.utf8)
        .write(to: directory.appending(path: "a.json"))
    try Data("not json".utf8).write(to: directory.appending(path: "broken.json"))
    try Data("{}".utf8).write(to: directory.appending(path: "notes.txt"))

    #expect(ModelLists.parseMuseCatalog(at: directory) == [
        AgentModelOption(id: "muse-a", label: "A", isDefault: true),
        AgentModelOption(id: "muse-b", label: "Bee", isDefault: false),
    ])
}

@Test func museLabelsTidyRawIDs() {
    #expect(ModelLists.museLabel(id: "muse-spark-1.3-contributor", display: "muse-spark-1.3-contributor") == "Spark 1.3 Contributor")
    #expect(ModelLists.museLabel(id: "muse-image-1.0", display: "Muse Image") == "Muse Image")
    #expect(ModelLists.museLabel(id: "muse-spark-1.3", display: nil) == "Spark 1.3")
}

@Test func anOldThreadFileWithoutAModelStillDecodes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "desk-old-thread-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ThreadStore(directory: directory)
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let id = UUID()
    let messageID = UUID()
    let thread = Thread(
        id: id,
        title: "Old",
        createdAt: created,
        updatedAt: created,
        messages: [Message(id: messageID, author: .agent(.claude), body: "hi", createdAt: created)]
    )
    try store.save(thread)
    let url = directory.appending(path: "\(id.uuidString).json")
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(saved.contains("\"model\"") == false)

    let loaded = try #require(try store.load().first)
    #expect(loaded.messages.first?.model == nil)
    #expect(loaded.messages.first?.body == "hi")

    var withModel = thread
    withModel.messages[0].model = "claude-opus-5-5"
    try store.save(withModel)
    let roundTrip = try #require(try store.load().first)
    #expect(roundTrip.messages.first?.model == "claude-opus-5-5")
}
