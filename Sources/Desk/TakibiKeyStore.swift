import Foundation
import Security
import Synchronization

/// Takibi keys by name: `main` for the app's own key, an agent's raw value for that agent's.
protocol TakibiKeyStore: Sendable {
    func load() throws -> [String: String]
    func save(_ keys: [String: String]) throws
}

/// All keys in one login Keychain item, so a rebuilt app asks at most once. Only the app that
/// saved the item reads it without a prompt; any other program, an agent's shell included, asks you.
struct KeychainKeyStore: TakibiKeyStore {
    var service = "\(Brand.slug).takibi"
    var account = "keys"

    func load() throws -> [String: String] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return [:]
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TakibiFailure("Couldn't read Takibi keys from the Keychain. \(Self.describe(status))")
        }
        guard let keys = try? JSONDecoder().decode([String: String].self, from: data) else {
            // Saving over it would lose whatever it holds.
            throw TakibiFailure("The Takibi keys in the Keychain couldn't be read. Delete “\(service)” in Keychain Access, then paste your keys again.")
        }
        return keys
    }

    func save(_ keys: [String: String]) throws {
        if keys.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TakibiFailure("Couldn't update the Keychain. \(Self.describe(status))")
            }
            return
        }
        let data = try JSONEncoder().encode(keys)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "\(Brand.name) Takibi keys"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw TakibiFailure("Couldn't save to the Keychain. \(Self.describe(status))")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Error \(status)."
    }
}

/// For tests and previews: never touches the Keychain.
final class MemoryKeyStore: TakibiKeyStore {
    private let keys: Mutex<[String: String]>

    init(_ keys: [String: String] = [:]) {
        self.keys = Mutex(keys)
    }

    func load() throws -> [String: String] {
        keys.withLock { $0 }
    }

    func save(_ keys: [String: String]) throws {
        self.keys.withLock { $0 = keys }
    }
}

/// A key written for one run of an agent or the takibi CLI, in a private temporary folder,
/// and deleted when that run ends. The CLI only reads a key from a file.
struct TakibiKeyFile: Sendable {
    static let prefix = "\(Brand.slug)-takibi-"

    /// Folders not yet removed, so quitting mid-run can still delete them.
    private static let live = Mutex<Set<URL>>([])

    let folder: URL

    var path: String {
        folder.appending(path: "key", directoryHint: .notDirectory).path(percentEncoded: false)
    }

    /// The folder name carries this process's id, so a later launch can tell a crashed run's
    /// folder from one another running copy of the app still uses.
    static func write(_ key: String, in parent: URL = FileManager.default.temporaryDirectory) throws -> TakibiKeyFile {
        let folder = parent.appending(path: "\(prefix)\(getpid())-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = TakibiKeyFile(folder: folder)
        live.withLock { _ = $0.insert(folder) }
        do {
            try TakibiKey.write(key, to: URL(filePath: file.path))
        } catch {
            file.remove()
            throw error
        }
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
        Self.live.withLock { _ = $0.remove(folder) }
    }

    /// For quitting while an agent still runs.
    static func removeAll() {
        for folder in live.withLock({ $0 }) {
            TakibiKeyFile(folder: folder).remove()
        }
    }

    /// Folders whose app is no longer running, left behind by a crash.
    static func removeLeftovers(in parent: URL = FileManager.default.temporaryDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(prefix) {
            let owner = name.dropFirst(prefix.count).split(separator: "-").first.flatMap { pid_t($0) }
            if let owner, isRunning(owner) { continue }
            try? FileManager.default.removeItem(at: parent.appending(path: name, directoryHint: .isDirectory))
        }
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
