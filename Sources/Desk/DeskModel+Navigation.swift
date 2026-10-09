import Foundation

extension DeskModel {
    /// Selects the thread `step` rows away in sidebar order. It stops at either end.
    func selectAdjacentThread(_ step: Int) {
        let listed = visibleThreads
        guard !listed.isEmpty else { return }
        guard let current = listed.firstIndex(where: { $0.id == selection }) else {
            selection = listed[0].id
            return
        }
        selection = listed[min(max(current + step, 0), listed.count - 1)].id
    }

    func toggleArchiveOnSelection() {
        guard let selection, let thread = selectedThread else { return }
        if thread.archivedAt == nil {
            archive(selection)
        } else {
            unarchive(selection)
        }
    }

    func beginRenameOnSelection() {
        guard let selection else { return }
        beginRename(selection)
    }

    /// Shows a thread the sidebar may be hiding, then selects it.
    func openThread(_ id: Thread.ID) {
        guard let thread = threads.first(where: { $0.id == id }) else { return }
        searchText = ""
        showsArchived = thread.archivedAt != nil
        if !filteredThreads.contains(where: { $0.id == id }) {
            tagFilter = nil
        }
        selection = id
    }

    func markRead(_ id: Thread.ID?) {
        guard let id, unreadThreads.contains(id) else { return }
        unreadThreads.remove(id)
    }

    func appBecameActive() {
        markRead(selection)
    }

    /// Notifies once per send, and only when nobody is looking at the app.
    func finishTurn(in threadID: Thread.ID, stopped: Bool) {
        guard let thread = threads.first(where: { $0.id == threadID }), !isAppActive() else { return }
        unreadThreads.insert(threadID)
        notifier.turnFinished(threadID: threadID, title: thread.title, body: Self.notificationBody(thread, stopped: stopped))
    }

    static func notificationBody(_ thread: Thread, stopped: Bool) -> String {
        if stopped { return "Stopped" }
        guard let last = thread.messages.last else { return "" }
        let text = last.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 100 ? String(text.prefix(100)) + "…" : text
    }
}
