import Foundation

/// Muse keeps its MCP servers in `settings.json`. Every other key, and every `headers` value, passes through untouched.
enum MuseSettings {
    static func file(home: URL, environment: [String: String]) -> URL {
        let override = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = override.isEmpty
            ? home.appending(path: ".config", directoryHint: .isDirectory)
            : URL(filePath: AgentCommand.expandingTilde(override, home: home), directoryHint: .isDirectory)
        return root.appending(path: "muse/settings.json", directoryHint: .notDirectory)
    }

    static func servers(at file: URL) throws -> [ToolServer] {
        let servers = try load(file)["mcpServers"] as? [String: Any] ?? [:]
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let mode = nonemptyString(entry["mode"])?.lowercased()
            let status: ToolServer.Status = mode == "off" || mode == "disabled" ? .disabled : .configured
            return ToolServer(name: name, target: nonemptyString(entry["url"]) ?? nonemptyString(entry["command"]), status: status)
        }
    }

    static func add(name: String, url: URL, to file: URL) throws {
        var settings = try load(file)
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        guard servers[name] == nil else { throw ToolsFailure("A server named \(name) already exists.") }
        servers[name] = ["mode": "optional", "url": url.absoluteString]
        settings["mcpServers"] = servers
        try save(settings, to: file)
    }

    static func remove(name: String, from file: URL) throws {
        var settings = try load(file)
        var servers = settings["mcpServers"] as? [String: Any] ?? [:]
        guard servers.removeValue(forKey: name) != nil else { return }
        settings["mcpServers"] = servers
        try save(settings, to: file)
    }

    private static func load(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return [:] }
        do {
            let data = try Data(contentsOf: file)
            if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ToolsFailure("Muse's settings file isn't a JSON object, so \(Brand.name) left it alone.")
            }
            return object
        } catch let error as ToolsFailure {
            throw error
        } catch {
            throw ToolsFailure("Couldn't read Muse's settings file, so \(Brand.name) left it alone.")
        }
    }

    private static func save(_ settings: [String: Any], to file: URL) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: file, options: .atomic)
        } catch {
            throw ToolsFailure("Couldn't save Muse's settings file.")
        }
    }
}
