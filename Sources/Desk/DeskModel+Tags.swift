import AppKit
import Foundation

extension DeskModel {
    func takibiProject(for tag: String) -> TakibiProject? {
        let slug = TagLibrary.slug(tag)
        guard !slug.isEmpty else { return nil }
        return takibi.projects.first { TagLibrary.slug($0.name) == slug }
    }

    func importTakibiProjects() {
        for project in takibi.projects {
            createTag(project.name)
        }
    }

    func createTag(_ name: String) {
        let tag = canonicalTag(name)
        guard !tag.isEmpty else { return }
        guard !knownTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        knownTags.append(tag)
        saveKnownTags()
    }

    func renameTag(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let current = existingSpelling(old) else { return }
        let replacement: String
        if let other = existingSpelling(trimmed), other.caseInsensitiveCompare(current) != .orderedSame {
            replacement = other
        } else {
            replacement = trimmed
        }
        guard replacement != current else { return }
        rewrite(current, to: replacement)
        moveLogo(from: current, to: replacement)
        if let tagFilter, tagFilter.caseInsensitiveCompare(current) == .orderedSame {
            self.tagFilter = replacement
        }
        logos.invalidate(TagLibrary.slug(current))
        logos.invalidate(TagLibrary.slug(replacement))
        logoRevision += 1
        saveKnownTags()
    }

    func deleteTag(_ name: String) {
        guard let current = existingSpelling(name) else { return }
        knownTags.removeAll { $0.caseInsensitiveCompare(current) == .orderedSame }
        for index in threads.indices {
            let updated = threads[index].tags.filter { $0.caseInsensitiveCompare(current) != .orderedSame }
            if updated.count != threads[index].tags.count {
                threads[index].tags = updated
                persist(threads[index])
            }
        }
        let url = TagLibrary.logoURL(current, in: supportDirectory)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            do {
                try trash(url)
            } catch {
                tagsError = "Couldn't remove the logo for \(current): \(error.localizedDescription)"
            }
        }
        if let tagFilter, tagFilter.caseInsensitiveCompare(current) == .orderedSame {
            self.tagFilter = nil
        }
        logos.invalidate(TagLibrary.slug(current))
        logoRevision += 1
        saveKnownTags()
    }

    func setLogo(for tag: String, from url: URL) throws {
        let data = try ScaledImage.png(from: url)
        try FileManager.default.createDirectory(at: TagLibrary.clientsDirectory(in: supportDirectory), withIntermediateDirectories: true)
        try data.write(to: TagLibrary.logoURL(tag, in: supportDirectory), options: .atomic)
        logos.invalidate(TagLibrary.slug(tag))
        logoRevision += 1
    }

    func removeLogo(for tag: String) {
        let url = TagLibrary.logoURL(tag, in: supportDirectory)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                tagsError = "Couldn't remove the logo for \(tag): \(error.localizedDescription)"
                return
            }
        }
        logos.invalidate(TagLibrary.slug(tag))
        logoRevision += 1
    }

    func logo(for tag: String) -> NSImage? {
        _ = logoRevision
        return logos.image(slug: TagLibrary.slug(tag), url: TagLibrary.logoURL(tag, in: supportDirectory))
    }

    func toggleTag(_ tag: String, on threadID: Thread.ID) {
        let name = canonicalTag(tag)
        guard !name.isEmpty, let threadIndex = index(of: threadID) else { return }
        if let existing = threads[threadIndex].tags.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            threads[threadIndex].tags.remove(at: existing)
        } else {
            threads[threadIndex].tags.append(name)
        }
        persist(threads[threadIndex])
        keepSelectionVisible()
    }

    func addTag(named name: String, to threadID: Thread.ID) {
        let tag = canonicalTag(name)
        guard !tag.isEmpty, let threadIndex = index(of: threadID) else { return }
        guard !threads[threadIndex].tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        threads[threadIndex].tags.append(tag)
        persist(threads[threadIndex])
    }

    func canonicalTag(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return existingSpelling(trimmed) ?? trimmed
    }

    /// Names that differ only in case or in spaces versus hyphens are one tag: they'd share a logo file.
    private func existingSpelling(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let slug = TagLibrary.slug(trimmed)
        if let known = knownTags.first(where: { TagLibrary.slug($0) == slug }) {
            return known
        }
        for thread in threads {
            if let tag = thread.tags.first(where: { TagLibrary.slug($0) == slug }) {
                return tag
            }
        }
        return nil
    }

    private func rewrite(_ old: String, to new: String) {
        var seen = Set<String>()
        var next: [String] = []
        for tag in knownTags {
            let value = tag.caseInsensitiveCompare(old) == .orderedSame ? new : tag
            if seen.insert(value.lowercased()).inserted {
                next.append(value)
            }
        }
        knownTags = next
        for index in threads.indices {
            var seenTags = Set<String>()
            var updated: [String] = []
            var changed = false
            for tag in threads[index].tags {
                let value = tag.caseInsensitiveCompare(old) == .orderedSame ? new : tag
                if value != tag { changed = true }
                if seenTags.insert(value.lowercased()).inserted {
                    updated.append(value)
                } else {
                    changed = true
                }
            }
            if changed {
                threads[index].tags = updated
                persist(threads[index])
            }
        }
    }

    private func moveLogo(from old: String, to new: String) {
        let oldSlug = TagLibrary.slug(old)
        let newSlug = TagLibrary.slug(new)
        guard oldSlug != newSlug else { return }
        let source = TagLibrary.logoURL(old, in: supportDirectory)
        let destination = TagLibrary.logoURL(new, in: supportDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        do {
            try fileManager.createDirectory(at: TagLibrary.clientsDirectory(in: supportDirectory), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        } catch {
            tagsError = "Couldn't move the logo for \(new): \(error.localizedDescription)"
        }
    }

    func saveKnownTags() {
        do {
            try TagLibrary.save(knownTags, to: supportDirectory)
            tagsError = nil
        } catch {
            tagsError = "Couldn't save tags: \(error.localizedDescription)"
        }
    }
}
