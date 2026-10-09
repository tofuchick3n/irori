import AppKit
import Foundation

extension DeskModel {
    /// Moves a thread out of the main list. A thread that's replying stays until it's done.
    func archive(_ id: Thread.ID) {
        guard runningThreadID != id, let threadIndex = index(of: id) else { return }
        threads[threadIndex].archivedAt = .now
        persist(threads[threadIndex])
        keepSelectionVisible()
    }

    func unarchive(_ id: Thread.ID) {
        guard let threadIndex = index(of: id) else { return }
        threads[threadIndex].archivedAt = nil
        persist(threads[threadIndex])
        if showsArchived {
            showsArchived = archivedCount > 0
            selection = id
        }
        keepSelectionVisible()
    }

    func newThread() {
        showsArchived = false
        // Reuse an empty thread that is untagged or already in the filtered client, never
        // another client's thread, so a filter can't pull it into a second client.
        let reusable = orderedThreads.first { thread in
            thread.archivedAt == nil && thread.messages.isEmpty && queuedMessage(in: thread.id) == nil && (thread.tags.isEmpty || filteredThreads.contains { $0.id == thread.id } && tagFilter != nil)
        }
        if let empty = reusable {
            selection = empty.id
            if let tagFilter, empty.tags.isEmpty {
                addTag(named: tagFilter, to: empty.id)
            }
            return
        }
        var thread = Thread()
        if let tagFilter {
            let tag = canonicalTag(tagFilter)
            if !tag.isEmpty {
                thread.tags = [tag]
            }
        }
        threads.append(thread)
        selection = thread.id
        draft = ""
        persist(thread)
    }

    func beginRename(_ id: Thread.ID) {
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        renameTarget = id
        renameText = thread.title
        isRenaming = true
    }

    func commitRename() {
        defer { renameTarget = nil }
        guard let id = renameTarget, let threadIndex = index(of: id) else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        threads[threadIndex].title = title
        persist(threads[threadIndex])
    }

    func delete(_ id: Thread.ID) {
        do {
            try store.delete(id: id)
        } catch {
            let title = threads.first { $0.id == id }?.title ?? "this thread"
            storageFailures[id] = "Couldn't delete “\(title)”: \(error.localizedDescription)"
            failedDeletes.insert(id)
            return
        }
        failedDeletes.remove(id)
        storageFailures[id] = nil
        queue.removeAll { $0.threadID == id }
        let task = runningThreadID == id ? runTask : nil
        // Ends this thread's turn without Stop's clearing of other threads' queued messages.
        if let task {
            task.cancel()
            denyPendingApprovals()
        }
        threads.removeAll { $0.id == id }
        drafts[id] = nil
        pendingAttachments[id] = nil
        unreadThreads.remove(id)
        if selection == id {
            selection = nil
        }
        guard let task else {
            trashWorkspace(for: id)
            return
        }
        Task { @MainActor in
            await task.value
            trashWorkspace(for: id)
        }
    }

    func workspaceURL(for threadID: Thread.ID) -> URL {
        workspacesDirectory.appending(path: threadID.uuidString, directoryHint: .isDirectory)
    }

    func openSelectedThreadFolder() {
        guard let selection else { return }
        let folder = workspaceURL(for: selection)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func trashWorkspace(for id: Thread.ID) {
        let url = workspaceURL(for: id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }
        try? trash(url)
    }
}
