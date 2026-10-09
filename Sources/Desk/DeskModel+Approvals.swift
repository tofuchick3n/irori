import Foundation

extension DeskModel {
    func approvalHandler(agent: AgentID, threadID: Thread.ID) -> ApprovalHandler {
        { [weak self] request in
            await self?.requestApproval(request, agent: agent, threadID: threadID) ?? .deny
        }
    }

    /// Answers allow at once for a rule the person already allowed; otherwise adds a card and waits for `decide`.
    func requestApproval(_ request: ApprovalRequest, agent: AgentID, threadID: Thread.ID) async -> ApprovalDecision {
        guard let threadIndex = index(of: threadID), runTask?.isCancelled != true else { return .deny }
        if isAllowed(request, in: threads[threadIndex]) { return .allowOnce }
        var card = Message(author: .notice, body: request.title)
        card.approval = ApprovalRecord(agent: agent, title: request.title, detail: request.detail, rule: request.rule)
        threads[threadIndex].messages.append(card)
        persist(threads[threadIndex])
        if !isAppActive() {
            notifier.waitingForApproval(
                threadID: threadID,
                title: threads[threadIndex].title,
                body: "\(agent.displayName) is waiting for your OK"
            )
        }
        return await withCheckedContinuation { continuation in
            approvalWaiters[card.id] = continuation
        }
    }

    /// A shell command runs without asking when every program in it is read-only or already allowed,
    /// and nothing in it writes a file or substitutes a command. `allowsEverything` skips the check.
    func isAllowed(_ request: ApprovalRequest, in thread: Thread) -> Bool {
        if thread.allowsEverything { return true }
        guard ApprovalRule.program(in: request.rule) != nil else {
            return alwaysAllowedTools.contains(request.rule) || thread.allowedRules.contains(request.rule)
        }
        guard let command = request.detail, let programs = ApprovalRule.shellPrograms(command) else { return false }
        return programs.allSatisfy { program in
            let rule = "Bash(\(program):*)"
            return ReadOnlyShell.allows(program, in: command)
                || allowedCommands.contains(program)
                || alwaysAllowedTools.contains(rule)
                || thread.allowedRules.contains(rule)
        }
    }

    func decide(_ messageID: Message.ID, _ decision: ApprovalDecision) {
        guard let waiter = approvalWaiters.removeValue(forKey: messageID) else { return }
        record(decision, for: messageID)
        waiter.resume(returning: decision)
    }

    /// Stop, or a run that ended with cards still open, answers no.
    func denyPendingApprovals() {
        for id in Array(approvalWaiters.keys) {
            decide(id, .deny)
        }
    }

    func removeAlwaysAllowed(_ rule: String) {
        alwaysAllowedTools.removeAll { $0 == rule }
    }

    func stopAllowingEverything(_ threadID: Thread.ID) {
        guard let threadIndex = index(of: threadID), threads[threadIndex].allowsEverything else { return }
        threads[threadIndex].allowsEverything = false
        persist(threads[threadIndex])
    }

    func resetThreadPermissions(_ threadID: Thread.ID) {
        guard let threadIndex = index(of: threadID) else { return }
        guard !threads[threadIndex].allowedRules.isEmpty || threads[threadIndex].allowsEverything else { return }
        threads[threadIndex].allowedRules = []
        threads[threadIndex].allowsEverything = false
        persist(threads[threadIndex])
    }

    private func record(_ decision: ApprovalDecision, for messageID: Message.ID) {
        guard let threadIndex = threads.firstIndex(where: { $0.messages.contains { $0.id == messageID } }),
              let messageIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == messageID }),
              var approval = threads[threadIndex].messages[messageIndex].approval else { return }
        approval.decision = decision
        threads[threadIndex].messages[messageIndex].approval = approval
        let answeredAt = threads[threadIndex].messages[messageIndex].createdAt
        // An answered card moves above the streaming reply, so the reply's text stays at the bottom.
        if let replyIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == streamingMessageID }),
           replyIndex < messageIndex {
            let card = threads[threadIndex].messages.remove(at: messageIndex)
            threads[threadIndex].messages.insert(card, at: replyIndex)
        }
        // An allow joins that reply's work log. The card itself leaves the transcript.
        if decision.allows,
           let replyIndex = threads[threadIndex].messages.firstIndex(where: { $0.id == streamingMessageID }) {
            let step = WorkStep.approval(approval, id: messageID, at: answeredAt)
            if !threads[threadIndex].messages[replyIndex].steps.contains(where: { $0.id == step.id }) {
                threads[threadIndex].messages[replyIndex].steps.append(step)
            }
        }
        // Allowing a shell command remembers every program in it, not just the first.
        let programs = ApprovalRule.program(in: approval.rule) != nil
            ? DeniedCommand.programs(in: approval.detail ?? "", allowed: [])
            : []
        let rules = programs.isEmpty ? [approval.rule] : programs.map { "Bash(\($0):*)" }
        switch decision {
        case .allowInThread:
            for rule in rules where !threads[threadIndex].allowedRules.contains(rule) {
                threads[threadIndex].allowedRules.append(rule)
            }
        case .allowAlways:
            for rule in rules {
                if let program = ApprovalRule.program(in: rule) {
                    allowCommand(program)
                } else if !alwaysAllowedTools.contains(rule) {
                    alwaysAllowedTools.append(rule)
                }
            }
        case .allowEverything:
            threads[threadIndex].allowsEverything = true
        case .allowOnce, .deny:
            break
        }
        persist(threads[threadIndex])
    }
}
