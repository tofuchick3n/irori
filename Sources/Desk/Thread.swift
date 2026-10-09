import Foundation

struct Thread: Identifiable, Codable, Equatable, Sendable {
    static let untitled = "New Thread"

    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]
    /// Index of the last message each agent has seen. The next prompt starts after it.
    var cursors: [AgentID: Int]
    var sessions: [AgentID: String]
    var tags: [String]
    /// Set when the user archives the thread; archived threads leave the main list.
    var archivedAt: Date?
    /// Tool rules the person allowed for this thread only.
    var allowedRules: [String] = []
    /// Every later request in this thread is allowed, for every agent.
    var allowsEverything = false
    /// Mentions in user messages before this index no longer choose who replies to an unmentioned message.
    var mentionsFrom: Int = 0

    init(
        id: UUID = UUID(),
        title: String = Thread.untitled,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [Message] = [],
        cursors: [AgentID: Int] = [:],
        sessions: [AgentID: String] = [:],
        tags: [String] = [],
        archivedAt: Date? = nil,
        allowedRules: [String] = [],
        allowsEverything: Bool = false,
        mentionsFrom: Int = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.cursors = cursors
        self.sessions = sessions
        self.tags = tags
        self.archivedAt = archivedAt
        self.allowedRules = allowedRules
        self.allowsEverything = allowsEverything
        self.mentionsFrom = mentionsFrom
    }

    init(from decoder: Decoder) throws {
        let stored = try StoredThread(from: decoder)
        self.init(
            id: stored.id,
            title: stored.title,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            messages: stored.messages,
            cursors: stored.cursors,
            sessions: stored.sessions,
            tags: stored.tags ?? [],
            archivedAt: stored.archivedAt,
            allowedRules: stored.allowedRules ?? [],
            allowsEverything: stored.allowsEverything ?? false,
            mentionsFrom: stored.mentionsFrom ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        try StoredThread(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages,
            cursors: cursors,
            sessions: sessions,
            tags: tags,
            archivedAt: archivedAt,
            allowedRules: allowedRules.isEmpty ? nil : allowedRules,
            allowsEverything: allowsEverything ? true : nil,
            mentionsFrom: mentionsFrom == 0 ? nil : mentionsFrom
        ).encode(to: encoder)
    }
}

/// `tags`, `archivedAt`, `allowedRules`, `allowsEverything`, and `mentionsFrom` are optional so older thread files still decode.
private struct StoredThread: Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]
    var cursors: [AgentID: Int]
    var sessions: [AgentID: String]
    var tags: [String]?
    var archivedAt: Date?
    var allowedRules: [String]?
    var allowsEverything: Bool?
    var mentionsFrom: Int?
}
