import Foundation

struct ThreadStore: Sendable {
    let directory: URL

    static var applicationSupportDirectory: URL {
        supportDirectory.appending(path: "threads", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/<Brand.supportFolder>/workspaces/`
    static var workspacesDirectory: URL {
        supportDirectory.appending(path: "workspaces", directoryHint: .isDirectory)
    }

    static func workspaceDirectory(for id: Thread.ID) -> URL {
        workspacesDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static var supportDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return root.appending(path: Brand.supportFolder, directoryHint: .isDirectory)
    }

    func load() throws -> [Thread] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var threads: [Thread] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let thread = try? ThreadCoding.decode(data) {
                threads.append(thread)
            }
        }
        return threads
    }

    func save(_ thread: Thread) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try ThreadCoding.encode(thread)
        try data.write(to: fileURL(for: thread.id), options: .atomic)
    }

    func delete(id: Thread.ID) throws {
        let url = fileURL(for: id)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(for id: Thread.ID) -> URL {
        directory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }
}

private enum ThreadCoding {
    static func encode(_ thread: Thread) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return try encoder.encode(thread)
    }

    static func decode(_ data: Data) throws -> Thread {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
            }
            return date
        }
        return try decoder.decode(Thread.self, from: data)
    }

    private static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }
}
