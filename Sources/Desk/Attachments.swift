import Foundation
import UniformTypeIdentifiers

/// Files attached to a message: copied into the thread's folder, listed in prompts, and sent natively when they are images.
enum Attachments {
    static let folder = "attachments"
    static let claudeImageLimit = 5 * 1024 * 1024
    private static let claudeMediaTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
    ]

    /// Copies each file into `workspace/attachments/`, adding " 2", " 3" to a name already taken.
    /// Returns the relative paths in order, and the names that could not be copied.
    static func copy(_ sources: [URL], into workspace: URL) -> (paths: [String], failed: [String]) {
        let fileManager = FileManager.default
        let directory = workspace.appending(path: folder, directoryHint: .isDirectory)
        var paths: [String] = []
        var failed: [String] = []
        for source in sources {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = uniqueName(source.lastPathComponent, in: directory)
                try fileManager.copyItem(at: source, to: directory.appending(path: name, directoryHint: .notDirectory))
                paths.append("\(folder)/\(name)")
            } catch {
                failed.append(source.lastPathComponent)
            }
        }
        return (paths, failed)
    }

    static func uniqueName(_ name: String, in directory: URL) -> String {
        let fileManager = FileManager.default
        func taken(_ candidate: String) -> Bool {
            fileManager.fileExists(atPath: directory.appending(path: candidate, directoryHint: .notDirectory).path(percentEncoded: false))
        }
        guard taken(name) else { return name }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !taken(candidate) { return candidate }
            number += 1
        }
    }

    static func isImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// The media type Claude accepts for an image, nil for any other format.
    static func claudeMediaType(_ path: String) -> String? {
        claudeMediaTypes[(path as NSString).pathExtension.lowercased()]
    }

    /// Images on user messages the agent hasn't been given yet: those after its cursor.
    static func newImages(in messages: [Message], seenThrough cursor: Int?, workspace: URL) -> [URL] {
        let start = (cursor ?? -1) + 1
        guard start < messages.count else { return [] }
        return messages[start...]
            .filter { $0.author == .user }
            .flatMap(\.attachments)
            .filter(isImage)
            .map { workspace.appending(path: $0, directoryHint: .notDirectory) }
    }

    /// "Attached: attachments/plan.pdf, attachments/chart.png", or nil with nothing attached.
    static func promptLine(_ paths: [String]) -> String? {
        paths.isEmpty ? nil : "Attached: " + paths.joined(separator: ", ")
    }

    /// Claude's message content: the text, then a base64 block per supported image. Images over the limit or in
    /// another format are left out and named in `skipped`.
    static func claudeContent(prompt: String, images: [URL]) -> (content: Any, skipped: [String]) {
        guard !images.isEmpty else { return (prompt, []) }
        var blocks: [[String: Any]] = [["type": "text", "text": prompt]]
        var skipped: [String] = []
        for url in images {
            let name = url.lastPathComponent
            guard let mediaType = claudeMediaType(name),
                  let data = try? Data(contentsOf: url),
                  data.count <= claudeImageLimit else {
                skipped.append(name)
                continue
            }
            blocks.append(["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]])
        }
        return (blocks, skipped)
    }

    static func skippedNotice(_ names: [String]) -> String {
        "Claude didn't get \(names.joined(separator: ", ")) as an image: Claude takes png, jpeg, gif, and webp up to 5 MB. It can still read the file."
    }
}
