import Foundation
import Testing
@testable import Desk

@Test func renamedAppMovesTheOldFolderAndSettingsOnce() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "desk-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: support) }
    let source = LegacyData.sources[1]
    let old = support.appending(path: source.folder, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: old.appending(path: "threads"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: old.appending(path: "tags.json"))
    let suite = "desk-legacy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldKey = old.appending(path: "takibi-keys/claude.key").path(percentEncoded: false)

    LegacyData.migrate(applicationSupport: support, defaults: defaults, legacySettings: [
        source.defaultsDomain: [
            "defaultAgent": "grok",
            "takibi.key.claude": oldKey,
        ],
    ])

    let new = support.appending(path: Brand.supportFolder, directoryHint: .isDirectory)
    #expect(FileManager.default.fileExists(atPath: new.appending(path: "tags.json").path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
    #expect(defaults.string(forKey: "defaultAgent") == "grok")
    #expect(defaults.string(forKey: "takibi.key.claude") == new.appending(path: "takibi-keys/claude.key").path(percentEncoded: false))

    // A second run, or a new folder that already exists, changes nothing.
    defaults.set("codex", forKey: "defaultAgent")
    LegacyData.migrate(applicationSupport: support, defaults: defaults, legacySettings: [
        source.defaultsDomain: ["defaultAgent": "grok"],
    ])
    #expect(defaults.string(forKey: "defaultAgent") == "codex")
}

@Test func aNewBundleIDKeepsTheFolderAndBringsTheSettings() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "desk-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: support) }
    let source = LegacyData.sources[0]
    #expect(source.folder == Brand.supportFolder)
    let folder = support.appending(path: Brand.supportFolder, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder.appending(path: "threads"), withIntermediateDirectories: true)
    let suite = "desk-legacy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = folder.appending(path: "takibi-keys/claude.key").path(percentEncoded: false)

    LegacyData.migrate(applicationSupport: support, defaults: defaults, legacySettings: [
        source.defaultsDomain: ["defaultAgent": "grok", "takibi.key.claude": key],
    ])
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: "threads").path(percentEncoded: false)))
    #expect(defaults.string(forKey: "defaultAgent") == "grok")
    #expect(defaults.string(forKey: "takibi.key.claude") == key)
}

@Test func oldestNameMigratesWhenTheMiddleOneNeverRan() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "desk-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: support) }
    let source = LegacyData.sources[2]
    let old = support.appending(path: source.folder, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: old.appending(path: "threads"), withIntermediateDirectories: true)
    let suite = "desk-legacy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    LegacyData.migrate(applicationSupport: support, defaults: defaults, legacySettings: [
        source.defaultsDomain: ["profile.name": "Sam"],
    ])

    let new = support.appending(path: Brand.supportFolder, directoryHint: .isDirectory)
    #expect(FileManager.default.fileExists(atPath: new.appending(path: "threads").path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
    #expect(defaults.string(forKey: "profile.name") == "Sam")
}

@Test func settingsMoveEvenWithoutAnOldDataFolder() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "desk-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: support) }
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let suite = "desk-legacy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let domain = LegacyData.sources[0].defaultsDomain

    LegacyData.migrate(applicationSupport: support, defaults: defaults, legacySettings: [
        domain: ["profile.name": "Sam"],
    ])
    #expect(defaults.string(forKey: "profile.name") == "Sam")

    defaults.set("Alex", forKey: "profile.name")
    LegacyData.migrate(applicationSupport: support, defaults: defaults, legacySettings: [
        domain: ["profile.name": "Sam"],
    ])
    #expect(defaults.string(forKey: "profile.name") == "Alex")
}

@Test func oldMessagesStillDecode() throws {
    let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","author":{"user":{}},"body":"hi","createdAt":0}"#
    let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
    #expect(message.body == "hi")
    #expect(message.steps.isEmpty && message.files.isEmpty && message.thinking.isEmpty)
    #expect(message.startedAt == nil && message.deniedCommand == nil)

    var full = message
    full.steps = [.thinking(id: "t")]
    full.files = ["a.md"]
    full.deniedPrograms = ["jq"]
    let round = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(full))
    #expect(round == full)
}

@Test func onlyTheNewestOldNameBringsSettings() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "desk-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: support) }
    let suite = "desk-legacy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // The middle name already took the oldest one's settings, then cleared the key.
    LegacyData.migrate(applicationSupport: support, defaults: defaults, legacySettings: [
        LegacyData.sources[0].defaultsDomain: ["defaultAgent": "codex"],
        LegacyData.sources[1].defaultsDomain: ["defaultAgent": "grok", "takibi.key.claude": "/old/claude.key"],
    ])
    #expect(defaults.string(forKey: "defaultAgent") == "codex")
    #expect(defaults.object(forKey: "takibi.key.claude") == nil)
}

@Test func keyPathsStayWhenTheOldFolderCouldNotMove() throws {
    let support = FileManager.default.temporaryDirectory.appending(path: "desk-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: support) }
    let source = LegacyData.sources[1]
    let old = support.appending(path: source.folder, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support.appending(path: Brand.supportFolder), withIntermediateDirectories: true)
    let suite = "desk-legacy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldKey = old.appending(path: "takibi-keys/claude.key").path(percentEncoded: false)

    LegacyData.migrate(applicationSupport: support, defaults: defaults, legacySettings: [
        source.defaultsDomain: ["takibi.key.claude": oldKey],
    ])
    #expect(defaults.string(forKey: "takibi.key.claude") == oldKey)
}
