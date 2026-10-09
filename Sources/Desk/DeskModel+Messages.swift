import AppKit
import Foundation

extension DeskModel {
    func copy(_ message: Message, asMarkdown: Bool) {
        let text = asMarkdown ? message.body : MarkdownRenderer.plainText(MarkdownRenderer.render(message.body))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The last agent reply, with only notices after it, while nothing is running.
    func canRetry(_ messageID: Message.ID) -> Bool {
        guard !isRunning, let thread = selectedThread,
              let index = thread.messages.firstIndex(where: { $0.id == messageID }),
              case .agent(let agent) = thread.messages[index].author,
              activeAgents.contains(agent) else { return false }
        return thread.messages[(index + 1)...].allSatisfy { $0.author == .notice }
    }

    /// Runs the same agent again without its old session, from the whole thread before the reply.
    func retry(_ messageID: Message.ID) {
        guard canRetry(messageID), let threadID = selection, let threadIndex = index(of: threadID),
              let messageIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == messageID }),
              case .agent(let agent) = threads[threadIndex].messages[messageIndex].author else { return }
        threads[threadIndex].messages.removeSubrange(messageIndex...)
        threads[threadIndex].mentionsFrom = min(threads[threadIndex].mentionsFrom, messageIndex)
        threads[threadIndex].cursors[agent] = nil
        threads[threadIndex].sessions[agent] = nil
        persist(threads[threadIndex])
        startRun([agent], in: threadID)
    }

    /// Adds files to the next message, skipping folders and files already added.
    func addAttachments(_ urls: [URL]) {
        for url in urls where url.isFileURL && !attachments.contains(url) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            attachments.append(url)
        }
    }

    func removeAttachment(_ url: URL) {
        attachments.removeAll { $0 == url }
    }

    func canEdit(_ messageID: Message.ID) -> Bool {
        guard !isRunning, let thread = selectedThread,
              let last = thread.messages.last(where: { $0.author == .user }) else { return false }
        return last.id == messageID
    }

    /// Takes the message back into the draft and drops it and everything after it.
    func edit(_ messageID: Message.ID) {
        guard canEdit(messageID), let threadID = selection, let threadIndex = index(of: threadID),
              let messageIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == messageID }) else { return }
        let text = threads[threadIndex].messages[messageIndex].body
        let workspace = workspaceURL(for: threadID)
        let attached = threads[threadIndex].messages[messageIndex].attachments.map { workspace.appending(path: $0, directoryHint: .notDirectory) }
        threads[threadIndex].messages.removeSubrange(messageIndex...)
        threads[threadIndex].mentionsFrom = min(threads[threadIndex].mentionsFrom, messageIndex)
        for (agent, cursor) in threads[threadIndex].cursors where cursor >= messageIndex {
            threads[threadIndex].cursors[agent] = nil
            threads[threadIndex].sessions[agent] = nil
        }
        draft = text
        attachments = attached
        persist(threads[threadIndex])
    }
}
