import Foundation

extension DeskModel {
    func requestTakibiSave(messageID: Message.ID, card: String, agent: AgentID) {
        guard !isRunning, let thread = selectedThread else { return }
        guard let cardID = TakibiCard.id(from: card) else { return }
        guard let message = thread.messages.first(where: { $0.id == messageID }) else { return }
        // Send through the draft, then put back whatever the user was typing.
        let unsent = draft
        let unsentAttachments = attachments
        attachments = []
        draft = TakibiCard.request(agent: agent, message: message, cardID: cardID)
        send()
        draft = unsent
        attachments = unsentAttachments
    }

    func send() {
        guard let threadID = selection, index(of: threadID) != nil else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let files = attachments
        if isRunning {
            guard queuedMessage(in: threadID) == nil else { return }
            queue.append(QueuedMessage(threadID: threadID, text: text, attachments: files))
        }
        draft = ""
        attachments = []
        if !isRunning {
            deliver(text, attachments: files, to: threadID)
        }
    }

    /// The path every message takes to a turn, whether sent now or after waiting in the queue.
    /// A queued one doesn't `reveal` its thread, so it never moves the person away from where they are.
    func deliver(_ text: String, attachments files: [URL], to threadID: Thread.ID, reveal: Bool = true) {
        guard let threadIndex = index(of: threadID) else { return }
        // Replying to an archived thread brings it back.
        if threads[threadIndex].archivedAt != nil {
            threads[threadIndex].archivedAt = nil
            if reveal {
                showsArchived = false
                selection = threadID
            }
        }
        let earlier = userTexts(in: threads[threadIndex])
        let plan = delivery(for: text, earlierUserTexts: earlier)
        var message = Message(author: .user, body: text)
        let copied = Attachments.copy(files, into: workspaceURL(for: threadID))
        message.attachments = copied.paths
        let isFirstMessage = !threads[threadIndex].messages.contains { $0.author == .user }
        threads[threadIndex].messages.append(message)
        if !copied.failed.isEmpty {
            threads[threadIndex].messages.append(Message(author: .notice, body: "Couldn't attach \(copied.failed.joined(separator: ", "))."))
        }
        for notice in plan.notices {
            threads[threadIndex].messages.append(Message(author: .notice, body: notice))
        }
        if isFirstMessage {
            threads[threadIndex].title = Turn.title(for: text.isEmpty ? (copied.paths.first.map { ($0 as NSString).lastPathComponent } ?? text) : text)
        }
        threads[threadIndex].updatedAt = .now
        persist(threads[threadIndex])
        let recipients = plan.recipients
        guard !recipients.isEmpty else { return }
        startRun(recipients, in: threadID)
    }

    func startRun(_ recipients: [AgentID], in threadID: Thread.ID) {
        runningThreadID = threadID
        runTask = Task { @MainActor in
            await run(recipients, in: threadID)
            let stopped = Task.isCancelled
            if runningThreadID == threadID {
                runningThreadID = nil
            }
            runTask = nil
            runningAgent = nil
            streamingMessageID = nil
            activity = nil
            denyPendingApprovals()
            finishTurn(in: threadID, stopped: stopped)
            // Stop already cleared the queue, so anything here was sent after it and should go.
            sendNextQueued()
        }
    }

    func stop() {
        clearQueue()
        runTask?.cancel()
        denyPendingApprovals()
    }

    private func run(_ recipients: [AgentID], in threadID: Thread.ID) async {
        for agent in recipients {
            if Task.isCancelled { return }
            let keepGoing = await run(agent, in: threadID)
            if !keepGoing || Task.isCancelled { return }
        }
    }

    private func run(_ agent: AgentID, in threadID: Thread.ID) async -> Bool {
        defer { activity = nil }
        guard let threadIndex = index(of: threadID) else { return false }
        var prompt = agentPrompt(
            messages: threads[threadIndex].messages,
            seenThrough: threads[threadIndex].cursors[agent],
            tags: threads[threadIndex].tags
        )
        let workspace = workspaceURL(for: threadID)
        var images = Attachments.newImages(in: threads[threadIndex].messages, seenThrough: threads[threadIndex].cursors[agent], workspace: workspace)
        var session = threads[threadIndex].sessions[agent]
        let modelID = modelForRun(for: agent)
        let effortID = effortForRun(for: agent)
        let replyID = UUID()
        var reply = Message(id: replyID, author: .agent(agent), body: "", model: modelID, effort: effortID)
        reply.startedAt = .now
        threads[threadIndex].messages.append(reply)
        streamingMessageID = replyID
        runningAgent = agent
        activity = nil

        let before = FolderSnapshot(workspace)
        var stopQueue = false
        var retriedMissingSession = false
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            while true {
                let gate = AgentExitGate()
                var failure: Error?
                do {
                    try await AgentRunGate.$current.withValue(gate) {
                        let stream = runner.run(
                            agent: agent,
                            prompt: prompt,
                            session: session,
                            workspace: workspace,
                            model: modelID,
                            effort: effortID,
                            permissions: AgentPermissions(
                                allowsFileWrites: allowsFileWrites,
                                allowedCommands: allowedCommands,
                                keyFile: environmentKeyFile(for: agent),
                                allowedRules: alwaysAllowedTools + threads[threadIndex].allowedRules,
                                images: images
                            ),
                            executable: launchExecutable(for: agent),
                            approve: approvalHandler(agent: agent, threadID: threadID)
                        )
                        let live = LiveReply(id: replyID) { [weak self] events in
                            for event in events {
                                self?.apply(event, threadID: threadID, replyID: replyID, agent: agent)
                            }
                        }
                        liveReply = live
                        defer {
                            live.flush()
                            if liveReply === live { liveReply = nil }
                        }
                        for try await event in stream {
                            try Task.checkCancellation()
                            if live.hold(event) {
                                if case .text = event, activity != nil { activity = nil }
                            } else {
                                // Other events, like a step starting, follow the text before them.
                                live.flush()
                                apply(event, threadID: threadID, replyID: replyID, agent: agent)
                            }
                        }
                    }
                } catch {
                    failure = error
                }
                await gate.wait()
                if let failure {
                    if failure is CancellationError {
                        stopQueue = true
                        break
                    }
                    if let error = failure as? AgentRunError,
                       error.missingSession,
                       !retriedMissingSession,
                       !replyHasText(threadID: threadID, replyID: replyID) {
                        retriedMissingSession = true
                        guard noteMissingSession(agent: agent, threadID: threadID, replyID: replyID) else {
                            stopQueue = true
                            break
                        }
                        prompt = retryPrompt(threadID: threadID, replyID: replyID)
                        images = retryImages(threadID: threadID, replyID: replyID, workspace: workspace)
                        session = nil
                        continue
                    }
                    await reportFailure(failure, agent: agent, threadID: threadID)
                    stopQueue = true
                    break
                }
                break
            }
        } catch is CancellationError {
            stopQueue = true
        } catch {
            apply(.notice(error.localizedDescription), threadID: threadID, replyID: replyID, agent: agent)
            stopQueue = true
        }
        if Task.isCancelled {
            stopQueue = true
        }

        guard let threadIndex = index(of: threadID) else {
            streamingMessageID = nil
            return false
        }
        if streamingMessageID == replyID {
            streamingMessageID = nil
        }
        var keptReply = false
        if let messageIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == replyID }) {
            let now = Date.now
            threads[threadIndex].messages[messageIndex].finishedAt = now
            for stepIndex in threads[threadIndex].messages[messageIndex].steps.indices
            where threads[threadIndex].messages[messageIndex].steps[stepIndex].state == .running {
                threads[threadIndex].messages[messageIndex].steps[stepIndex].state = stopQueue ? .failed : .done
                threads[threadIndex].messages[messageIndex].steps[stepIndex].endedAt = now
            }
            threads[threadIndex].messages[messageIndex].files = FolderSnapshot(workspace).changes(since: before)
            if threads[threadIndex].messages[messageIndex].body.isEmpty {
                threads[threadIndex].messages.remove(at: messageIndex)
                if !stopQueue {
                    threads[threadIndex].messages.insert(
                        Message(author: .notice, body: "\(agent.displayName) finished without replying."),
                        at: messageIndex
                    )
                }
            } else {
                keptReply = true
            }
        }
        if keptReply, let last = threads[threadIndex].messages.indices.last {
            threads[threadIndex].cursors[agent] = last
        }
        // `updatedAt` orders the sidebar, and only the person's own messages move a thread up,
        // so the list doesn't reshuffle under the pointer as each agent finishes.
        persist(threads[threadIndex])
        return !stopQueue
    }

    private func replyHasText(threadID: Thread.ID, replyID: Message.ID) -> Bool {
        guard let threadIndex = index(of: threadID),
              let message = threads[threadIndex].messages.first(where: { $0.id == replyID }) else {
            return false
        }
        return !message.body.isEmpty
    }

    private func noteMissingSession(agent: AgentID, threadID: Thread.ID, replyID: Message.ID) -> Bool {
        guard let threadIndex = index(of: threadID),
              let replyIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == replyID }) else {
            return false
        }
        threads[threadIndex].sessions[agent] = nil
        let notice = "\(agent.displayName)'s earlier session wasn't found, so it started a new one with the full thread."
        threads[threadIndex].messages.insert(Message(author: .notice, body: notice), at: replyIndex)
        return true
    }

    private func retryPrompt(threadID: Thread.ID, replyID: Message.ID) -> String {
        guard let threadIndex = index(of: threadID),
              let replyIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == replyID }) else {
            return ""
        }
        return agentPrompt(
            messages: Array(threads[threadIndex].messages[..<replyIndex]),
            seenThrough: nil,
            tags: threads[threadIndex].tags
        )
    }

    private func retryImages(threadID: Thread.ID, replyID: Message.ID, workspace: URL) -> [URL] {
        guard let threadIndex = index(of: threadID),
              let replyIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == replyID }) else {
            return []
        }
        return Attachments.newImages(in: Array(threads[threadIndex].messages[..<replyIndex]), seenThrough: nil, workspace: workspace)
    }

    private func apply(_ event: AgentEvent, threadID: Thread.ID, replyID: Message.ID, agent: AgentID) {
        guard let threadIndex = index(of: threadID) else { return }
        switch event {
        case .text(let chunk):
            activity = nil
            guard let messageIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == replyID }) else { return }
            threads[threadIndex].messages[messageIndex].body += chunk
        case .notice(let text):
            threads[threadIndex].messages.append(Message(author: .notice, body: text))
        case .session(let id):
            threads[threadIndex].sessions[agent] = id
        case .model(let id):
            guard !id.isEmpty, let messageIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == replyID }) else { return }
            threads[threadIndex].messages[messageIndex].model = id
        case .activity(let status):
            activity = status
        case .stepStarted(let step):
            updateReply(threadIndex, replyID) { reply in
                if let existing = reply.steps.firstIndex(where: { $0.id == step.id }) {
                    // A step reported again only learns its title; its timing and state stay.
                    reply.steps[existing].kind = step.kind
                    reply.steps[existing].title = step.title
                    reply.steps[existing].detail = step.detail
                } else {
                    reply.steps.append(step)
                }
            }
        case .stepFinished(let id, let failed):
            updateReply(threadIndex, replyID) { reply in
                guard let index = reply.steps.firstIndex(where: { $0.id == id }), reply.steps[index].state == .running else { return }
                reply.steps[index].state = failed ? .failed : .done
                reply.steps[index].endedAt = .now
            }
        case .thinking(let text):
            updateReply(threadIndex, replyID) { $0.thinking += text }
        case .denied(let tool, let command):
            threads[threadIndex].messages.append(Self.deniedNotice(
                agent: agent,
                tool: tool,
                command: command,
                allowed: allowedCommands
            ))
        }
    }

    /// A missing CLI or a signed-out account says what to do; anything else keeps the CLI's own message.
    private func reportFailure(_ failure: Error, agent: AgentID, threadID: Thread.ID) async {
        var notice = Message(author: .notice, body: failure.localizedDescription)
        if (failure as? AgentRunError)?.notInstalled == true {
            notice.body = "\(agent.displayName) isn't installed."
            notice.fix = .openSettings
            notice.fixAgent = agent
        } else if await checkSignIn(for: agent) == .signedOut {
            notice.body = "\(agent.displayName) isn't signed in."
            notice.fix = .signIn
            notice.fixAgent = agent
        }
        guard let threadIndex = index(of: threadID) else { return }
        threads[threadIndex].messages.append(notice)
    }

    func performFix(_ message: Message) {
        switch message.fix {
        case .signIn:
            if let agent = message.fixAgent { openSignIn(for: agent) }
        case .openSettings:
            settingsTab = "Agents"
        case nil:
            break
        }
    }

    private func updateReply(_ threadIndex: Int, _ replyID: Message.ID, _ change: (inout Message) -> Void) {
        guard let messageIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == replyID }) else { return }
        change(&threads[threadIndex].messages[messageIndex])
    }

    /// "Claude was refused python3." with the command kept for "Show Command" and the programs for "Allow".
    nonisolated static func deniedNotice(agent: AgentID, tool: String, command: String?, allowed: [String]) -> Message {
        let isShell = ["Bash", "bash", "run_terminal_command", "shell"].contains(tool)
        let programs = isShell ? command.map { DeniedCommand.programs(in: $0, allowed: allowed) } ?? [] : []
        let refused = programs.isEmpty ? tool : programs.joined(separator: ", ")
        var notice = Message(author: .notice, body: "\(agent.displayName) was refused \(refused).")
        notice.deniedCommand = command
        notice.deniedPrograms = programs
        return notice
    }

    func delivery(for text: String, earlierUserTexts: [String]) -> (recipients: [AgentID], notices: [String]) {
        if activeAgents.isEmpty {
            return ([], ["No agents are available. Install one, or turn one on in Settings."])
        }
        if !Turn.mentionedAgents(in: text).isEmpty {
            var recipients: [AgentID] = []
            var notices: [String] = []
            for agent in Turn.mentionedAgents(in: text, all: activeAgents) {
                if activeAgents.contains(agent) {
                    if !recipients.contains(agent) {
                        recipients.append(agent)
                    }
                } else {
                    let notice = inactiveNotice(for: agent)
                    if !notices.contains(notice) {
                        notices.append(notice)
                    }
                }
            }
            return (recipients, notices)
        }
        let fallback = effectiveDefaultAgent ?? activeAgents[0]
        let resolved = Turn.recipients(for: text, earlierUserTexts: earlierUserTexts, fallback: fallback, all: activeAgents)
        let recipients = resolved.filter { activeAgents.contains($0) }
        if recipients.isEmpty, let agent = effectiveDefaultAgent {
            return ([agent], [])
        }
        return (recipients, [])
    }

    private func inactiveNotice(for agent: AgentID) -> String {
        if !isEnabled(agent) {
            return "\(agent.displayName) is turned off in Settings."
        }
        return "\(agent.displayName) isn't installed."
    }

    private func agentPrompt(messages: [Message], seenThrough cursor: Int?, tags: [String]) -> String {
        let transcript = Turn.prompt(messages: messages, seenThrough: cursor)
        let context = [ThreadContext.tagLine(tags), TakibiContext.line(tags: tags, projects: takibi.projects)].compactMap { $0 }
        return (context + [transcript]).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
