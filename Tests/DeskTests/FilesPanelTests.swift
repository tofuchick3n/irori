import Foundation
import SwiftUI
import Testing
@testable import Desk

@MainActor
struct FilesPanelTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "desk-files-panel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func laterRepliesWinTheAuthorMap() {
        var first = Message(author: .agent(.grok), body: "a")
        first.files = ["a.md"]
        let user = Message(author: .user, body: "hi")
        var second = Message(author: .agent(.codex), body: "b")
        second.files = ["a.md", "b.md"]
        #expect(ThreadFile.authors(in: [first, user, second]) == ["a.md": .codex, "b.md": .codex])
    }

    @Test func rowsCarryPreformattedDateAndSize() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try String(repeating: "x", count: 1500).write(to: folder.appending(path: "a.md"), atomically: true, encoding: .utf8)

        let files = try #require(ThreadFile.list(in: folder, authors: [:]))
        let file = try #require(files.first)
        #expect(!file.modifiedText.isEmpty)
        #expect(!file.sizeText.isEmpty)
    }

    @Test func aCancelledScanReturnsNil() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "x".write(to: folder.appending(path: "a.md"), atomically: true, encoding: .utf8)
        #expect(try #require(ThreadFile.list(in: folder, authors: [:])).count == 1)

        let cancelled: [ThreadFile]? = await withTaskGroup(of: [ThreadFile]?.self) { group in
            group.cancelAll()
            group.addTask { ThreadFile.list(in: folder, authors: [:]) }
            return await group.next() ?? nil
        }
        #expect(cancelled == nil)
    }

    @Test func drawerEqualityTracksItsInputs() {
        let folder = URL(filePath: "/tmp/desk-drawer", directoryHint: .isDirectory)
        let drawer = FilesDrawer(folder: folder, revision: 1, authors: [:], selection: .constant(nil))
        #expect(drawer == FilesDrawer(folder: folder, revision: 1, authors: [:], selection: .constant(nil)))
        #expect(drawer != FilesDrawer(folder: folder, revision: 2, authors: [:], selection: .constant(nil)))
        #expect(drawer != FilesDrawer(folder: folder, revision: 1, authors: ["a.md": .grok], selection: .constant(nil)))
        #expect(drawer != FilesDrawer(folder: folder, revision: 1, authors: [:], selection: .constant("a.md")))
    }

    @Test func markdownLoadsAsStyledText() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "a.md")
        try "# Hello\n".write(to: url, atomically: true, encoding: .utf8)

        let payload = PreviewPayload.load(url: url, kind: .markdown)
        guard case .attributed(let text) = payload else {
            Issue.record("expected styled text for a small markdown file")
            return
        }
        #expect(text.value.string.contains("Hello"))
    }

    @Test func textOverTheCapFallsBack() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "big.txt")
        try String(repeating: "x", count: PreviewPayload.textLimit + 1).write(to: url, atomically: true, encoding: .utf8)

        let payload = PreviewPayload.load(url: url, kind: .text)
        guard case .unsupported = payload else {
            Issue.record("expected no inline preview over the text cap")
            return
        }
    }

    @Test func missingFilesFallBack() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = PreviewPayload.load(url: folder.appending(path: "gone.md"), kind: .markdown)
        guard case .unsupported = payload else {
            Issue.record("expected no preview for a missing file")
            return
        }
    }

    @Test func largeImagesDownsampleToPanelSize() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "big.png")
        try writePNG(width: 2000, height: 100, to: url)

        let payload = PreviewPayload.load(url: url, kind: .image)
        guard case .image(let image) = payload else {
            Issue.record("expected an image payload")
            return
        }
        #expect(max(image.value.size.width, image.value.size.height) <= 480)
    }

    @Test func vectorImagesStillPreview() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "mark.svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#.write(to: url, atomically: true, encoding: .utf8)

        let payload = PreviewPayload.load(url: url, kind: .image)
        guard case .image = payload else {
            Issue.record("expected an image payload for SVG")
            return
        }
    }
}
