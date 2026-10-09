import Foundation

extension DeskModel {
    func queuedMessage(in threadID: Thread.ID?) -> QueuedMessage? {
        queue.first { $0.threadID == threadID }
    }

    func cancelQueued(in threadID: Thread.ID) {
        guard let queued = queuedMessage(in: threadID) else { return }
        queue.removeAll { $0.id == queued.id }
        restore(queued)
    }

    /// Puts a queued message back in its thread's composer, after anything typed there since, so
    /// nothing is lost whichever thread is open.
    func restore(_ queued: QueuedMessage) {
        let typed = drafts[queued.threadID] ?? ""
        drafts[queued.threadID] = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? queued.text
            : typed + "\n\n" + queued.text
        let files = pendingAttachments[queued.threadID] ?? []
        pendingAttachments[queued.threadID] = files + queued.attachments.filter { !files.contains($0) }
    }

    func clearQueue() {
        let dropped = queue
        queue = []
        for queued in dropped {
            restore(queued)
        }
    }

    /// ⌘↩: the draft goes out next, cutting the turn in progress short. With nothing typed, the open
    /// thread's queued message goes instead. Other queued messages keep their places.
    func sendNow() {
        guard isRunning, let threadID = selection else { return send() }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, attachments.isEmpty {
            sendQueuedNow(in: threadID)
            return
        }
        // Typed more while one was queued: both go now, as one message.
        var combinedText = text
        var combinedFiles = attachments
        if let waiting = queuedMessage(in: threadID) {
            queue.removeAll { $0.id == waiting.id }
            combinedText = [waiting.text, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            combinedFiles = waiting.attachments + attachments.filter { !waiting.attachments.contains($0) }
        }
        queue.insert(QueuedMessage(threadID: threadID, text: combinedText, attachments: combinedFiles), at: 0)
        draft = ""
        attachments = []
        interrupt()
    }

    func sendQueuedNow(in threadID: Thread.ID) {
        guard let index = queue.firstIndex(where: { $0.threadID == threadID }) else { return }
        queue.insert(queue.remove(at: index), at: 0)
        if isRunning {
            interrupt()
        } else {
            sendNextQueued()
        }
    }

    /// Ends the turn in progress like Stop, but leaves the queue to go out after it.
    private func interrupt() {
        runTask?.cancel()
        denyPendingApprovals()
    }

    /// Sends the oldest queued message that starts a turn; one with nobody to reply is skipped.
    func sendNextQueued() {
        while !isRunning, !queue.isEmpty {
            let next = queue.removeFirst()
            deliver(next.text, attachments: next.attachments, to: next.threadID, reveal: false)
        }
    }
}
