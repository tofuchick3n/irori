import Foundation

/// Brings data and settings over from the app's earlier names and bundle ids (irori under
/// com.takibibase.irori, "Takibi Base Companion", then "goBOFU Desk") the first time the renamed
/// app runs: the data folder if the new one doesn't exist yet, and the newest old domain's settings once.
enum LegacyData {
    struct Source: Sendable {
        var folder: String
        var defaultsDomain: String
    }

    static let sources = [
        Source(folder: "Irori", defaultsDomain: "com.takibibase.irori"),
        Source(folder: "Takibi Base Companion", defaultsDomain: "com.takibibase.companion"),
        Source(folder: "goBOFU Desk", defaultsDomain: "com.gobofu.desk"),
    ]

    private static func migratedKey(for source: Source) -> String {
        "legacy.migrated.\(source.defaultsDomain)"
    }

    static func migrate(
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        defaults: UserDefaults = .standard,
        legacySettings: [String: [String: Any]]? = nil
    ) {
        let new = applicationSupport.appending(path: Brand.supportFolder, directoryHint: .isDirectory)
        let fileManager = FileManager.default
        for source in sources {
            let old = applicationSupport.appending(path: source.folder, directoryHint: .isDirectory)
            if !fileManager.fileExists(atPath: new.path(percentEncoded: false)),
               fileManager.fileExists(atPath: old.path(percentEncoded: false)) {
                try? fileManager.moveItem(at: old, to: new)
                break
            }
        }
        // Settings move on their own: someone may have changed them without ever saving a thread.
        let settings = legacySettings ?? Dictionary(
            uniqueKeysWithValues: sources.compactMap { source in
                UserDefaults(suiteName: source.defaultsDomain)?.persistentDomain(forName: source.defaultsDomain)
                    .map { (source.defaultsDomain, $0) }
            }
        )
        // Only the newest earlier name: it already took over the one before it, so an older domain
        // would bring back settings cleared since.
        guard let source = sources.first(where: { settings[$0.defaultsDomain] != nil }),
              let legacy = settings[source.defaultsDomain],
              !defaults.bool(forKey: migratedKey(for: source))
        else { return }
        let oldPrefix = applicationSupport.appending(path: source.folder, directoryHint: .isDirectory)
            .path(percentEncoded: false)
        let newPrefix = new.path(percentEncoded: false)
        // Paths into the old folder follow it only if it moved.
        let moved = !fileManager.fileExists(atPath: oldPrefix)
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            // Per-agent Takibi key files lived inside the old folder.
            if moved, let path = value as? String, path.hasPrefix(oldPrefix) {
                defaults.set(newPrefix + path.dropFirst(oldPrefix.count), forKey: key)
            } else {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migratedKey(for: source))
    }
}
