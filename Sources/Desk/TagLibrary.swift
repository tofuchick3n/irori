import AppKit
import Foundation

enum TagLibrary {
    /// A file-name-safe form of a tag: letters and digits, everything else one hyphen.
    /// It also names the tag's logo, so it must never carry a path separator or `..`.
    static func slug(_ tag: String) -> String {
        var slug = ""
        for character in tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.last == "-" {
            slug.removeLast()
        }
        return slug.isEmpty ? "tag" : slug
    }

    static func clientsDirectory(in directory: URL) -> URL {
        directory.appending(path: "clients", directoryHint: .isDirectory)
    }

    static func logoURL(_ tag: String, in directory: URL) -> URL {
        clientsDirectory(in: directory).appending(path: "\(slug(tag)).png", directoryHint: .notDirectory)
    }

    static func load(from directory: URL) -> [String] {
        let url = directory.appending(path: "tags.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(StoredTags.self, from: data) else {
            return []
        }
        return unique(file.tags)
    }

    static func save(_ tags: [String], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(StoredTags(tags: unique(tags)))
        try data.write(to: directory.appending(path: "tags.json", directoryHint: .notDirectory), options: .atomic)
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

private struct StoredTags: Codable {
    var tags: [String]
}

@MainActor
final class LogoCache {
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func image(slug: String, url: URL) -> NSImage? {
        if let image = images[slug] {
            return image
        }
        if missing.contains(slug) {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else {
            missing.insert(slug)
            return nil
        }
        images[slug] = image
        return image
    }

    func invalidate(_ slug: String) {
        images[slug] = nil
        missing.remove(slug)
    }
}
