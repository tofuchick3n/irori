import Foundation

enum MuseCommand {
    static func sessionRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".local/share/muse/sessions", directoryHint: .isDirectory)
    }

    static func modelCatalogDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".local/share/muse/model-catalog", directoryHint: .isDirectory)
    }

    /// Muse sessions live at `root/YYYY/MM/DD/<id>/`. A missing directory means the id cannot be resumed.
    static func hasSessionDirectory(id: String, root: URL) -> Bool {
        guard !id.isEmpty else { return false }
        let fileManager = FileManager.default
        guard let years = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        for year in years where isDirectory(year) {
            guard let months = try? fileManager.contentsOfDirectory(at: year, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for month in months where isDirectory(month) {
                guard let days = try? fileManager.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                    continue
                }
                for day in days where isDirectory(day) {
                    if isDirectory(day.appending(path: id, directoryHint: .isDirectory)) {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func deliveredPrompt(_ prompt: String, session: String?) -> String {
        if let session, !session.isEmpty {
            return prompt
        }
        return AgentCommand.roundtablePrompt(for: "Muse") + "\n\n" + prompt
    }

    static func arguments(
        prompt: String,
        session: String?,
        workspace: URL,
        model: String? = nil,
        effort: String? = nil,
        allowsFileWrites: Bool = true,
        images: [URL] = []
    ) -> [String] {
        var args = [
            "exec",
            "--json",
            "--provider", "meta",
            "--workspace", workspace.path(percentEncoded: false),
            "--approval-mode", "never",
        ]
        if !allowsFileWrites {
            // --disable-write alone still lets Muse write through its shell (verified live).
            args.append(contentsOf: ["--disable-write", "--disable-shell"])
        }
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        if let effort, !effort.isEmpty {
            args.append(contentsOf: ["--reasoning-effort", effort])
        }
        if let session, !session.isEmpty {
            args.append(contentsOf: ["--session-id", session])
        }
        for image in images {
            args.append(contentsOf: ["--image", image.path(percentEncoded: false)])
        }
        args.append(deliveredPrompt(prompt, session: session))
        return args
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func candidatePaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            home.appending(path: ".local/bin/muse", directoryHint: .notDirectory).path(percentEncoded: false),
            "/opt/homebrew/bin/muse",
            "/usr/local/bin/muse",
        ]
    }
}
