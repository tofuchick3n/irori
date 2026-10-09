import Foundation

/// A message sent while a turn was running. It waits in memory, so quitting drops it.
struct QueuedMessage: Identifiable, Equatable {
    let id = UUID()
    let threadID: Thread.ID
    let text: String
    let attachments: [URL]
    let createdAt = Date.now
}
