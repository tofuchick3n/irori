import Foundation
import Testing
@testable import Desk

@Test func folderSnapshotFindsCreatedAndChangedFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "desk-snap-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder.appending(path: ".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "same".write(to: folder.appending(path: "same.md"), atomically: true, encoding: .utf8)
    try "old".write(to: folder.appending(path: "changed.md"), atomically: true, encoding: .utf8)
    let before = FolderSnapshot(folder)

    try "new, longer".write(to: folder.appending(path: "changed.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: folder.appending(path: "out"), withIntermediateDirectories: true)
    try "x".write(to: folder.appending(path: "out/report.html"), atomically: true, encoding: .utf8)
    try "x".write(to: folder.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)

    #expect(FolderSnapshot(folder).changes(since: before) == ["changed.md", "out/report.html"])
}
