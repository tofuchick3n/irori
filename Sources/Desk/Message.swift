import Foundation

enum Fix: String, Codable, Sendable {
    case signIn, openSettings
}

struct Message: Identifiable, Codable, Equatable, Sendable {
    enum Author: Codable, Equatable, Sendable {
        case user
        case agent(AgentID)
        case notice
    }

    var id: UUID
    var author: Author
    var body: String
    var createdAt: Date
    var model: String?
    /// The effort the reply was asked for. Nil means the CLI's own default.
    var effort: String?
    var steps: [WorkStep] = []
    /// Reasoning the agent showed while it worked.
    var thinking = ""
    var startedAt: Date?
    var finishedAt: Date?
    /// Paths, relative to the thread's folder, created or changed during the reply.
    var files: [String] = []
    /// On a user message: paths, relative to the thread's folder, of the files attached to it.
    var attachments: [String] = []
    /// On a refusal notice: the full command, and the programs in it that aren't allowed.
    var deniedCommand: String?
    var deniedPrograms: [String] = []
    /// On a failure notice: what the notice's button does, and for whom.
    var fix: Fix?
    var fixAgent: AgentID?
    /// On an approval notice: what the agent asked for and the answer.
    var approval: ApprovalRecord?

    init(id: UUID = UUID(), author: Author, body: String, createdAt: Date = .now, model: String? = nil, effort: String? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.model = model
        self.effort = effort
    }

    private enum CodingKeys: String, CodingKey {
        case id, author, body, createdAt, model, effort, steps, thinking, startedAt, finishedAt, files, deniedCommand, deniedPrograms, fix, fixAgent, approval, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        author = try container.decode(Author.self, forKey: .author)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        steps = try container.decodeIfPresent([WorkStep].self, forKey: .steps) ?? []
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
        deniedCommand = try container.decodeIfPresent(String.self, forKey: .deniedCommand)
        deniedPrograms = try container.decodeIfPresent([String].self, forKey: .deniedPrograms) ?? []
        fix = try container.decodeIfPresent(Fix.self, forKey: .fix)
        fixAgent = try container.decodeIfPresent(AgentID.self, forKey: .fixAgent)
        approval = try container.decodeIfPresent(ApprovalRecord.self, forKey: .approval)
        attachments = try container.decodeIfPresent([String].self, forKey: .attachments) ?? []
    }
}
