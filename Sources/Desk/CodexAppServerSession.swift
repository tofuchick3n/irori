import Foundation

/// One Codex turn over `codex app-server --stdio`. Speaks the JSON-RPC session and ignores Desk tool calls.
struct CodexAppServerSession: AgentLineParser {
    var stdin: AgentStdin
    var prompt: String
    var session: String?
    var workspace: URL
    var model: String?
    var effort: String? = nil
    var allowsFileWrites = true
    var images: [URL] = []
    var approve: ApprovalHandler = { _ in .deny }

    private var nextID = 0
    private var initializeID: Int?
    private var threadRequestID: Int?
    private var turnRequestID: Int?
    private var reportedModel: String?
    private var deltaItemIDs: Set<String> = []
    private var untaggedDelta = false
    /// The agent message the last text delta belonged to; a new one starts a new paragraph.
    private var lastDeltaItem: String?
    /// The reasoning item and summary part the last thinking text belonged to.
    private var lastThinkingPart: String?
    private(set) var finishedCleanly = false

    /// Spelled out: before Swift 6.4, the private properties made the memberwise one private.
    init(
        stdin: AgentStdin,
        prompt: String,
        session: String?,
        workspace: URL,
        model: String?,
        effort: String? = nil,
        allowsFileWrites: Bool = true,
        images: [URL] = [],
        approve: @escaping ApprovalHandler = { _ in .deny }
    ) {
        self.stdin = stdin
        self.prompt = prompt
        self.session = session
        self.workspace = workspace
        self.model = model
        self.effort = effort
        self.allowsFileWrites = allowsFileWrites
        self.images = images
        self.approve = approve
    }

    mutating func sessionStarted() {
        initializeID = send("initialize", params: CodexCommand.initializeParams())
    }

    mutating func events(from line: String) throws -> [AgentEvent] {
        guard let object = jsonObject(from: line) else { return [] }
        let id = jsonID(object["id"])
        let method = object["method"] as? String
        let result = object["result"]
        let error = object["error"]
        let hasResult = result != nil && !(result is NSNull)
        let hasError = error != nil && !(error is NSNull)

        if let method, let id, !hasResult, !hasError {
            if let request = ApprovalRequest.codex(method: method, id: "\(id.jsonValue)", params: object["params"] as? [String: Any] ?? [:]) {
                answer(request, to: id)
                return []
            }
            stdin.write(CodexCommand.rejectedRequest(id: id.jsonValue))
            return [.notice("Codex asked for \(method). \(Brand.name) denied it.")]
        }
        // Only a failure of Desk's own requests ends the turn; errors about anything else are ignored.
        if hasError, !hasResult, id == nil || matches(id, initializeID) || matches(id, threadRequestID) || matches(id, turnRequestID) {
            let message = Self.failureText(error) ?? "Codex failed."
            throw AgentRunError(
                message: message,
                missingSession: message.contains(CodexCommand.missingSessionMarker)
            )
        }
        if hasResult, matches(id, initializeID), threadRequestID == nil {
            stdin.write(CodexCommand.notification("initialized"))
            if let session, !session.isEmpty {
                threadRequestID = send("thread/resume", params: CodexCommand.threadResumeParams(
                    threadID: session,
                    workspace: workspace,
                    model: model,
                    allowsFileWrites: allowsFileWrites
                ))
            } else {
                threadRequestID = send("thread/start", params: CodexCommand.threadStartParams(
                    workspace: workspace,
                    model: model,
                    allowsFileWrites: allowsFileWrites
                ))
            }
            return []
        }
        if hasResult, matches(id, threadRequestID), turnRequestID == nil {
            return startTurn(result as? [String: Any])
        }
        if hasResult, matches(id, turnRequestID) {
            return modelEvents(in: result as? [String: Any])
        }
        guard let method else { return [] }
        let params = object["params"] as? [String: Any]
        switch method {
        case "item/agentMessage/delta":
            return textDelta(params)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return thinkingDelta(params)
        case "item/started", "item/completed":
            return itemEvents(params, method: method)
        case "turn/completed":
            if let turn = params?["turn"] as? [String: Any], let error = turn["error"], !(error is NSNull) {
                throw AgentRunError(message: Self.failureText(error) ?? "Codex failed.")
            }
            finishedCleanly = true
            stdin.close()
            return []
        case "turn/failed", "error":
            let message = Self.failureText(params?["turn"])
                ?? Self.failureText(params?["error"])
                ?? Self.failureText(params)
                ?? "Codex failed."
            let missing = message.contains(CodexCommand.missingSessionMarker)
            throw AgentRunError(message: message, missingSession: missing)
        default:
            return []
        }
    }

    private func answer(_ request: ApprovalRequest, to id: JSONID) {
        let stdin = stdin
        let approve = approve
        let accept = CodexCommand.approvalResponse(id: id.jsonValue, decision: .allowOnce)
        let decline = CodexCommand.approvalResponse(id: id.jsonValue, decision: .deny)
        Task {
            let decision = await approve(request)
            stdin.write(decision.allows ? accept : decline)
        }
    }

    private mutating func startTurn(_ result: [String: Any]?) -> [AgentEvent] {
        let thread = result?["thread"] as? [String: Any]
        guard let threadID = nonemptyString(thread?["id"])
            ?? nonemptyString(result?["threadId"])
            ?? nonemptyString(result?["thread_id"]) else {
            return []
        }
        var events: [AgentEvent] = [.session(threadID)]
        events.append(contentsOf: modelEvents(in: result, thread: thread))
        turnRequestID = send("turn/start", params: CodexCommand.turnStartParams(
            threadID: threadID,
            prompt: prompt,
            model: model,
            effort: effort,
            images: images
        ))
        return events
    }

    /// Each reasoning summary part is its own short paragraph, often a bold title; streamed
    /// back to back they ran together, so a new part starts after a blank line.
    private mutating func thinkingDelta(_ params: [String: Any]?) -> [AgentEvent] {
        guard let text = params?["delta"] as? String, !text.isEmpty else { return [] }
        let item = params?["itemId"] as? String ?? ""
        let index = params?["summaryIndex"] as? Int ?? params?["contentIndex"] as? Int ?? 0
        let part = "\(item)#\(index)"
        defer { lastThinkingPart = part }
        guard let last = lastThinkingPart, last != part else { return [.thinking(text)] }
        return [.thinking("\n\n" + text)]
    }

    private mutating func textDelta(_ params: [String: Any]?) -> [AgentEvent] {
        guard let text = params?["delta"] as? String, !text.isEmpty else { return [] }
        var prefix = ""
        if let id = nonemptyString(params?["itemId"]) ?? nonemptyString(params?["item_id"]) {
            if let last = lastDeltaItem, last != id {
                prefix = "\n\n"
            }
            lastDeltaItem = id
            deltaItemIDs.insert(id)
        } else {
            untaggedDelta = true
        }
        return [.text(prefix + text)]
    }

    private mutating func itemEvents(_ params: [String: Any]?, method: String) -> [AgentEvent] {
        guard let item = params?["item"] as? [String: Any] else { return [] }
        let type = item["type"] as? String ?? ""
        let itemID = nonemptyString(item["id"]) ?? UUID().uuidString
        if method == "item/started" {
            if type == "reasoning" || type == "reasoning_item" {
                return [.activity("Thinking"), .stepStarted(.thinking(id: itemID))]
            }
            if type == "commandExecution" || type == "command_execution" {
                let command = nonemptyString(item["command"]) ?? ""
                return [.activity(command.isEmpty ? "Running" : "Running `\(command)`"), .stepStarted(.command(id: itemID, command))]
            }
            if type == "fileChange" || type == "file_change" {
                let paths = Self.changedPaths(item)
                if paths.isEmpty {
                    return [.stepStarted(WorkStep(id: itemID, kind: .fileWrite, title: "Edited files"))]
                }
                return paths.enumerated().map { index, path in
                    .stepStarted(.fileWrite(id: index == 0 ? itemID : "\(itemID)-\(index)", path: path))
                }
            }
        }
        if method == "item/completed" {
            switch type {
            case "reasoning", "reasoning_item":
                return [.stepFinished(id: itemID, failed: false)]
            case "commandExecution", "command_execution":
                let status = (item["status"] as? String)?.lowercased()
                let exitCode = item["exitCode"] as? Int ?? item["exit_code"] as? Int
                let failed = status == "failed" || status == "declined" || (exitCode ?? 0) != 0
                return [.stepFinished(id: itemID, failed: failed)]
            case "fileChange", "file_change":
                let status = (item["status"] as? String)?.lowercased()
                let failed = status == "failed" || status == "declined"
                let count = max(1, Self.changedPaths(item).count)
                return (0..<count).map { .stepFinished(id: $0 == 0 ? itemID : "\(itemID)-\($0)", failed: failed) }
            default:
                break
            }
        }
        if method == "item/completed", type == "agentMessage" || type == "agent_message" {
            let id = nonemptyString(item["id"])
            if let id, deltaItemIDs.contains(id) {
                return []
            }
            if untaggedDelta {
                // Deltas without an item id belong to the next agent message that closes.
                untaggedDelta = false
                if let id {
                    deltaItemIDs.insert(id)
                }
                return []
            }
            if let text = nonemptyString(item["text"]) {
                let prefix = lastDeltaItem == nil ? "" : "\n\n"
                if let id {
                    deltaItemIDs.insert(id)
                    lastDeltaItem = id
                }
                return [.text(prefix + text)]
            }
        }
        return []
    }

    /// File paths in a file-change item, whether `changes` is a list of `{path}` or a map keyed by path.
    static func changedPaths(_ item: [String: Any]) -> [String] {
        if let list = item["changes"] as? [[String: Any]] {
            return list.compactMap { nonemptyString($0["path"]) }
        }
        if let map = item["changes"] as? [String: Any] {
            return map.keys.sorted()
        }
        return nonemptyString(item["path"]).map { [$0] } ?? []
    }

    private mutating func modelEvents(in result: [String: Any]?, thread: [String: Any]? = nil) -> [AgentEvent] {
        let thread = thread ?? result?["thread"] as? [String: Any]
        guard let id = nonemptyString(result?["model"]) ?? nonemptyString(thread?["model"]), id != reportedModel else {
            return []
        }
        reportedModel = id
        return [.model(id)]
    }

    private mutating func send(_ method: String, params: [String: Any]) -> Int {
        nextID += 1
        stdin.write(CodexCommand.request(method: method, id: nextID, params: params))
        return nextID
    }

    private func matches(_ id: JSONID?, _ expected: Int?) -> Bool {
        guard let expected, case .number(let value) = id else { return false }
        return value == expected
    }

    private static func failureText(_ value: Any?) -> String? {
        if let object = value as? [String: Any] {
            if let message = nonemptyString(object["message"]) {
                return message
            }
            if let nested = failureText(object["error"]) {
                return nested
            }
            return nil
        }
        return nonemptyString(value)
    }
}
