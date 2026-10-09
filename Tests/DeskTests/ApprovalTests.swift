import Foundation
import Synchronization
import Testing
@testable import Desk

private typealias DeskThread = Desk.Thread

private final class Requests: Sendable {
    private let seen = Mutex<[ApprovalRequest]>([])
    func add(_ request: ApprovalRequest) { seen.withLock { $0.append(request) } }
    var all: [ApprovalRequest] { seen.withLock { $0 } }
}

private func fixtureLines(_ name: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

private func waitFor(isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Rules

@Test func approvalRuleNamesTheFirstProgram() {
    #expect(ApprovalRule.make(tool: "Bash", input: ["command": "touch probe.txt"]) == "Bash(touch:*)")
    #expect(ApprovalRule.make(tool: "Bash", input: ["command": "FOO=1 BAR=2 /usr/bin/git status"]) == "Bash(git:*)")
    #expect(ApprovalRule.make(tool: "Bash", input: ["command": "cd x && ls"]) == "Bash(cd:*)")
    #expect(ApprovalRule.make(tool: "Bash", input: [:]) == "Bash")
    #expect(ApprovalRule.make(tool: "WebSearch", input: ["query": "x"]) == "WebSearch")
    #expect(ApprovalRule.make(tool: "mcp__gmail__send_message", input: [:]) == "mcp__gmail__send_message")
    #expect(ApprovalRule.program(in: "Bash(touch:*)") == "touch")
    #expect(ApprovalRule.program(in: "WebSearch") == nil)
}

@Test func approvalRulesHaveFriendlyNames() {
    #expect(ApprovalRule.friendlyName("WebSearch") == "Web search")
    #expect(ApprovalRule.friendlyName("mcp__gmail__send_message") == "Gmail: send_message")
    #expect(ApprovalRule.friendlyName("Bash(jq:*)") == "Run jq")
}

// MARK: - Claude

@Test func claudeArgumentsAskThroughStdinAndMergeAllowedRules() throws {
    let args = ClaudeCommand.arguments(session: nil, allowedCommands: ["takibi"], allowedRules: ["WebSearch", "Bash(takibi:*)", "mcp__gmail__send_message"])
    #expect(!args.contains("--permission-prompts"))
    #expect(args.first == "-p" && args[1] == "--verbose")
    let input = try #require(args.firstIndex(of: "--input-format"))
    #expect(args[input + 1] == "stream-json")
    let tool = try #require(args.firstIndex(of: "--permission-prompt-tool"))
    #expect(args[tool + 1] == "stdio")
    let rules = args.indices.filter { args[$0] == "--allowedTools" }.map { args[$0 + 1] }
    #expect(rules == ["Bash(takibi:*)", "WebSearch", "mcp__gmail__send_message"])
}

@Test func claudeFixtureRequestsBecomeApprovals() async throws {
    let requests = Requests()
    let stdin = AgentStdin()
    var session = ClaudeSession(stdin: stdin, prompt: "hi") { request in
        requests.add(request)
        return request.tool == "Bash" ? .deny : .allowOnce
    }
    session.sessionStarted()
    var events: [AgentEvent] = []
    for line in try fixtureLines("claude-approval-stream") {
        let before = stdin.writtenLines().count
        events += try session.events(from: line)
        if line.contains("\"can_use_tool\"") {
            try await waitFor { stdin.writtenLines().count > before }
        }
    }
    let all = requests.all
    #expect(all.count == 2)
    #expect(all[0] == ApprovalRequest(
        id: "5edf558b-075a-4d5e-977e-24138eb2685f",
        tool: "Bash",
        title: "Run touch probe.txt",
        detail: "touch probe.txt",
        rule: "Bash(touch:*)"
    ))
    #expect(all[1].tool == "WebSearch")
    #expect(all[1].title == "Search the web for “Swift 6.2 release date”")
    #expect(all[1].rule == "WebSearch")
    #expect(all[1].detail == #"{"mode":"standard","query":"Swift 6.2 release date"}"#)

    let written = stdin.writtenLines()
    #expect(written[0] == #"{"request":{"subtype":"initialize"},"request_id":"init-1","type":"control_request"}"#)
    #expect(written[1] == #"{"message":{"content":"hi","role":"user"},"type":"user"}"#)
    #expect(written[2] == #"{"response":{"request_id":"5edf558b-075a-4d5e-977e-24138eb2685f","response":{"behavior":"deny","message":"The user said no."},"subtype":"success"},"type":"control_response"}"#)
    #expect(written[3] == #"{"response":{"request_id":"e98edde6-8242-4a1f-acd8-bf84cb9167ad","response":{"behavior":"allow","updatedInput":{"mode":"standard","query":"Swift 6.2 release date"}},"subtype":"success"},"type":"control_response"}"#)
    #expect(session.finishedCleanly)
    let denied = events.filter { if case .denied = $0 { true } else { false } }
    #expect(denied.isEmpty)
}

@Test func claudeStillReportsDenialsDeskDidNotMake() throws {
    var session = ClaudeSession(stdin: AgentStdin(), prompt: "hi") { _ in .allowOnce }
    let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[{"tool_name":"Bash","tool_use_id":"toolu_x","tool_input":{"command":"ls"}}]}"#
    #expect(try session.events(from: result) == [.denied(tool: "Bash", command: "ls")])
}

// MARK: - Codex

private func codexSession(_ stdin: AgentStdin, _ requests: Requests, answer: ApprovalDecision) -> CodexAppServerSession {
    CodexAppServerSession(
        stdin: stdin,
        prompt: "hi",
        session: nil,
        workspace: URL(filePath: "/tmp/ws"),
        model: nil,
        approve: { request in
            requests.add(request)
            return answer
        }
    )
}

@Test func codexFixtureRequestBecomesAnApproval() async throws {
    let line = try #require(try fixtureLines("codex-approval-stream").first { $0.contains("requestApproval") })
    for (answer, expected) in [
        (ApprovalDecision.allowOnce, #"{"id":0,"result":{"decision":"accept"}}"#),
        (.allowAlways, #"{"id":0,"result":{"decision":"accept"}}"#),
        (.allowEverything, #"{"id":0,"result":{"decision":"accept"}}"#),
        (.deny, #"{"id":0,"result":{"decision":"decline"}}"#),
    ] {
        let requests = Requests()
        let stdin = AgentStdin()
        var session = codexSession(stdin, requests, answer: answer)
        #expect(try session.events(from: line).isEmpty)
        try await waitFor { !stdin.writtenLines().isEmpty }
        #expect(stdin.writtenLines() == [expected])
        #expect(requests.all == [ApprovalRequest(
            id: "0",
            tool: "Bash",
            title: "Run touch probe-a.txt",
            detail: "touch probe-a.txt",
            rule: "Bash(touch:*)"
        )])
    }
    #expect(CodexCommand.approvalResponse(id: 0, decision: .deny, cancelled: true) == #"{"id":0,"result":{"decision":"cancel"}}"#)
}

@Test func codexApprovalTitlesFallBackToReasonThenMethod() throws {
    let file = try #require(ApprovalRequest.codex(method: "item/fileChange/requestApproval", id: "3", params: ["reason": "write notes.md"]))
    #expect(file.tool == "Edit" && file.title == "write notes.md" && file.rule == "Edit")
    let other = try #require(ApprovalRequest.codex(method: "item/permissions/requestApproval", id: "4", params: [:]))
    #expect(other.title == "item/permissions/requestApproval")
    #expect(ApprovalRequest.codex(method: "item/tool/call", id: "5", params: [:]) == nil)
}

@Test func codexKeepsRejectingOtherServerRequests() throws {
    let stdin = AgentStdin()
    var session = codexSession(stdin, Requests(), answer: .allowOnce)
    _ = try session.events(from: #"{"method":"item/tool/call","id":9,"params":{}}"#)
    #expect(stdin.writtenLines() == [CodexCommand.rejectedRequest(id: 9)])
}

// MARK: - Storage

@Test func oldMessagesAndThreadsDecodeWithoutApprovalFields() throws {
    let thread = DeskThread(title: "Old", messages: [Message(author: .user, body: "hi")])
    let data = try JSONEncoder().encode(thread)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("allowedRules") && !text.contains("approval") && !text.contains("allowsEverything"))
    let decoded = try JSONDecoder().decode(DeskThread.self, from: data)
    #expect(decoded.allowedRules.isEmpty)
    #expect(!decoded.allowsEverything)
    #expect(decoded.messages[0].approval == nil)

    var fresh = DeskThread(title: "New", allowedRules: ["WebSearch"])
    var card = Message(author: .notice, body: "Run ls")
    card.approval = ApprovalRecord(agent: .claude, title: "Run ls", detail: "ls", rule: "Bash(ls:*)", decision: nil)
    fresh.messages = [card]
    let back = try JSONDecoder().decode(DeskThread.self, from: JSONEncoder().encode(fresh))
    #expect(back.allowedRules == ["WebSearch"])
    #expect(back.messages[0].approval == card.approval)
}

// MARK: - DeskModel

private final class AskingRunner: AgentRunner, Sendable {
    let request: ApprovalRequest
    let answers = Mutex<[ApprovalDecision]>([])

    init(_ request: ApprovalRequest) { self.request = request }

    func run(
        agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?,
        effort _: String?, permissions _: AgentPermissions, executable _: URL?,
        approve: @escaping ApprovalHandler
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let request = request
        return AsyncThrowingStream { continuation in
            let task = Task {
                let decision = await approve(request)
                answers.withLock { $0.append(decision) }
                continuation.yield(.text("done"))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@MainActor
private final class WaitingNotifier: TurnNotifier {
    var onOpen: (@MainActor (DeskThread.ID) -> Void)?
    var waiting: [String] = []
    func turnFinished(threadID _: DeskThread.ID, title _: String, body _: String) {}
    func waitingForApproval(threadID _: DeskThread.ID, title _: String, body: String) { waiting.append(body) }
    func setBadge(_: Int) {}
}

@MainActor
private struct Rig {
    var model: DeskModel
    var runner: AskingRunner
    var notifier: WaitingNotifier
    var directory: URL

    init(rule: String, command: String = "npm test", active: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "desk-approval-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runner = AskingRunner(ApprovalRequest(id: "1", tool: "Bash", title: "Run \(command)", detail: command, rule: rule))
        notifier = WaitingNotifier()
        model = DeskModel(
            store: ThreadStore(directory: directory),
            runner: runner,
            defaults: UserDefaults(suiteName: "desk-approval-\(UUID().uuidString)")!,
            notifier: notifier,
            isAppActive: { active }
        )
        model.newThread()
    }

    var cards: [Message] { model.selectedThread?.messages.filter { $0.approval != nil } ?? [] }

    func ask() async throws {
        model.draft = "@claude go"
        model.send()
    }

    func finish() async throws {
        try await waitFor { !model.isRunning }
        #expect(!model.isRunning)
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForCard() async throws -> Message {
        try await waitFor { !model.approvalWaiters.isEmpty }
        return try #require(cards.first)
    }
}

@MainActor
@Suite struct ApprovalModelTests {
    @Test func theThreeListsAllowWithoutACard() async throws {
        for setup in ["always", "thread", "command"] {
            let rig = setup == "command"
                ? try Rig(rule: "Bash(takibi:*)", command: "takibi tasks list")
                : try Rig(rule: "mcp__x__y")
            switch setup {
            case "always": rig.model.alwaysAllowedTools.append("mcp__x__y")
            case "thread": rig.model.threads[0].allowedRules = ["mcp__x__y"]
            default: break
            }
            try await rig.ask()
            try await rig.finish()
            #expect(rig.cards.isEmpty, "\(setup)")
            #expect(rig.runner.answers.withLock { $0 } == [.allowOnce], "\(setup)")
        }
    }

    @Test func aNewRuleRecordsACardAndWaits() async throws {
        let rig = try Rig(rule: "Bash(npm:*)", active: false)
        try await rig.ask()
        let card = try await rig.waitForCard()
        #expect(card.approval?.decision == nil)
        #expect(card.approval?.title == "Run npm test")
        #expect(card.approval?.agent == .claude)
        #expect(rig.notifier.waiting == ["Claude is waiting for your OK"])
        #expect(rig.runner.answers.withLock { $0 }.isEmpty)
        rig.model.decide(card.id, .allowOnce)
        try await rig.finish()
        #expect(rig.cards.first?.approval?.decision == .allowOnce)
        #expect(rig.runner.answers.withLock { $0 } == [.allowOnce])
        #expect(rig.model.approvalWaiters.isEmpty)
    }

    @Test func anAnsweredCardMovesAboveTheReply() async throws {
        let rig = try Rig(rule: "Bash(npm:*)")
        try await rig.ask()
        let card = try await rig.waitForCard()
        let waiting = try #require(rig.model.selectedThread?.messages.map(\.id))
        #expect(waiting.last == card.id)
        rig.model.decide(card.id, .allowOnce)
        try await rig.finish()
        let messages = try #require(rig.model.selectedThread?.messages)
        #expect(messages.last?.body == "done")
        #expect(messages[messages.count - 2].id == card.id)
    }

    @Test func noNotificationWhileTheAppIsActive() async throws {
        let rig = try Rig(rule: "Bash(npm:*)", active: true)
        try await rig.ask()
        let card = try await rig.waitForCard()
        #expect(rig.notifier.waiting.isEmpty)
        rig.model.decide(card.id, .deny)
        try await rig.finish()
    }

    @Test func eachDecisionChangesTheRightList() async throws {
        let cases: [(ApprovalDecision, String)] = [
            (.allowOnce, "Bash(npm:*)"), (.allowInThread, "Bash(npm:*)"), (.allowAlways, "Bash(npm:*)"),
            (.allowAlways, "mcp__gmail__send_message"), (.deny, "Bash(npm:*)"),
        ]
        for (decision, rule) in cases {
            let rig = try Rig(rule: rule)
            let tools = rig.model.alwaysAllowedTools
            let commands = rig.model.allowedCommands
            try await rig.ask()
            let card = try await rig.waitForCard()
            rig.model.decide(card.id, decision)
            try await rig.finish()
            let thread = try #require(rig.model.selectedThread)
            #expect(rig.runner.answers.withLock { $0 } == [decision])
            #expect(thread.allowedRules == (decision == .allowInThread ? [rule] : []))
            let alwaysTool = decision == .allowAlways && !rule.hasPrefix("Bash(")
            #expect(rig.model.alwaysAllowedTools == (alwaysTool ? tools + [rule] : tools))
            let alwaysCommand = decision == .allowAlways && rule.hasPrefix("Bash(")
            #expect(rig.model.allowedCommands == (alwaysCommand ? commands + ["npm"] : commands))
        }
    }

    @Test func aShellCommandRunsWithoutAskingOnlyWhenEveryProgramIsAllowed() async throws {
        let cases: [(command: String, asks: Bool)] = [
            ("takibi tasks list | jq .", false),
            ("takibi tasks list && rm -rf notes", true),
            ("takibi $(rm -rf notes)", true),
            ("takibi tasks list > ~/.zshrc", true),
        ]
        for (command, asks) in cases {
            let rig = try Rig(rule: "Bash(takibi:*)", command: command)
            rig.model.allowCommand("jq")
            try await rig.ask()
            if asks {
                let card = try await rig.waitForCard()
                rig.model.decide(card.id, .deny)
            }
            try await rig.finish()
            #expect(rig.cards.isEmpty == !asks, "\(command)")
        }
    }

    @Test func allowingACompoundCommandRemembersEveryProgram() async throws {
        let rig = try Rig(rule: "Bash(git:*)", command: "git status && npm test")
        try await rig.ask()
        let card = try await rig.waitForCard()
        rig.model.decide(card.id, .allowInThread)
        try await rig.finish()
        #expect(rig.model.selectedThread?.allowedRules == ["Bash(git:*)", "Bash(npm:*)"])
    }

    @Test func stopWhileWaitingDenies() async throws {
        let rig = try Rig(rule: "Bash(npm:*)")
        try await rig.ask()
        _ = try await rig.waitForCard()
        rig.model.stop()
        try await rig.finish()
        #expect(rig.cards.first?.approval?.decision == .deny)
        #expect(rig.runner.answers.withLock { $0 } == [.deny])
        #expect(rig.model.approvalWaiters.isEmpty)
    }

    @Test func resetAndRemoveClearTheLists() throws {
        let rig = try Rig(rule: "x")
        let id = try #require(rig.model.selection)
        rig.model.threads[0].allowedRules = ["WebSearch"]
        rig.model.threads[0].allowsEverything = true
        rig.model.resetThreadPermissions(id)
        #expect(rig.model.threads[0].allowedRules.isEmpty)
        #expect(!rig.model.threads[0].allowsEverything)
        #expect(rig.model.alwaysAllowedTools == ["WebSearch", "WebFetch"])
        rig.model.removeAlwaysAllowed("WebSearch")
        #expect(rig.model.alwaysAllowedTools == ["WebFetch"])

        rig.model.threads[0].allowsEverything = true
        rig.model.resetThreadPermissions(id)
        #expect(!rig.model.threads[0].allowsEverything)
    }

    @Test func readOnlyCommandsDoNotAskAndWritesStillDo() async throws {
        let rig = try Rig(rule: "Bash(ls:*)", command: "ls")
        let thread = rig.model.threads[0]
        func asks(_ command: String) -> Bool {
            let request = ApprovalRequest(id: "1", tool: "Bash", title: "Run \(command)", detail: command, rule: "Bash(x:*)")
            return !rig.model.isAllowed(request, in: rig.model.threads[0])
        }
        #expect(!asks("ls"))
        #expect(!asks("ls -la && git status"))
        #expect(!asks("find . -name x"))
        #expect(!asks("git status"))
        #expect(!asks("git branch"))
        #expect(!asks("git remote -v"))
        #expect(!asks("ls 2>&1"))
        #expect(!asks("ls 1>&2"))
        #expect(!asks("ls >&2"))
        #expect(!asks("ls 2>/dev/null"))
        #expect(!asks("ls >/dev/null"))
        #expect(!asks("ls &>/dev/null"))
        #expect(!asks("ls 1>/dev/null"))
        #expect(!asks(#"D=/tmp cat "$D/file""#))
        #expect(asks("sed -i '' file"))
        #expect(asks("rm file"))
        #expect(asks("tee file"))
        #expect(asks("xargs rm"))
        #expect(asks("env ls"))
        #expect(asks("sh -c ls"))
        #expect(asks("ls > file"))
        #expect(asks("ls >> file"))
        #expect(asks("find . -delete"))
        #expect(asks("find . -exec rm {} \\;"))
        #expect(asks("git branch -d foo"))
        #expect(asks("git commit"))
        #expect(asks("echo $(date)"))
        rig.model.allowCommand("npm")
        #expect(!asks("npm test 2>&1"))
        #expect(asks("npm test > out.txt"))
        #expect(thread.allowsEverything == false)
        try await rig.finish()
    }

    @Test func aReadOnlyCommandNeverOpensACard() async throws {
        let rig = try Rig(rule: "Bash(ls:*)", command: "ls -la && git status")
        try await rig.ask()
        try await rig.finish()
        #expect(rig.cards.isEmpty)
        #expect(rig.runner.answers.withLock { $0 } == [.allowOnce])
    }

    @Test func anAnsweredAllowJoinsTheWorkLogAndADenialStays() async throws {
        let allowed = try Rig(rule: "Bash(npm:*)", command: "npm test")
        try await allowed.ask()
        let card = try await allowed.waitForCard()
        allowed.model.decide(card.id, .allowOnce)
        try await allowed.finish()
        let messages = try #require(allowed.model.selectedThread?.messages)
        let rows = TranscriptRows.rows(in: messages)
        #expect(rows.allSatisfy { $0.message.approval?.decision?.allows != true })
        let reply = try #require(rows.last { if case .agent = $0.message.author { true } else { false } })
        let shown = reply.approvalSteps + reply.message.steps
        #expect(shown.map(\.title) == ["Allowed once: Run npm test"])
        #expect(shown.first?.kind == .approval && shown.first?.state == .done)
        #expect(reply.approvalSteps.isEmpty)

        let denied = try Rig(rule: "Bash(npm:*)", command: "npm test")
        try await denied.ask()
        let denial = try await denied.waitForCard()
        denied.model.decide(denial.id, .deny)
        try await denied.finish()
        let deniedRows = TranscriptRows.rows(in: try #require(denied.model.selectedThread?.messages))
        #expect(deniedRows.contains { $0.message.id == denial.id && $0.message.approval?.decision == .deny })
        #expect(deniedRows.allSatisfy { $0.approvalSteps.isEmpty && !$0.message.steps.contains { $0.kind == .approval } })
    }

    @Test func allowEverythingSkipsLaterRequestsInThatThreadOnly() async throws {
        let rig = try Rig(rule: "Bash(rm:*)", command: "rm -rf notes")
        let id = try #require(rig.model.selection)
        try await rig.ask()
        let card = try await rig.waitForCard()
        rig.model.decide(card.id, .allowEverything)
        try await waitFor { !rig.model.isRunning }

        let thread = try #require(rig.model.selectedThread)
        #expect(thread.allowsEverything)
        #expect(rig.runner.answers.withLock { $0 } == [.allowEverything])
        let bash = ApprovalRequest(id: "2", tool: "Bash", title: "Run rm -rf notes", detail: "rm -rf notes", rule: "Bash(rm:*)")
        let edit = ApprovalRequest(id: "3", tool: "Edit", title: "Edit files", detail: nil, rule: "Edit")
        #expect(rig.model.isAllowed(bash, in: thread))
        #expect(rig.model.isAllowed(edit, in: thread))
        let elsewhere = DeskThread(title: "Elsewhere")
        #expect(!rig.model.isAllowed(bash, in: elsewhere))
        #expect(!rig.model.isAllowed(edit, in: elsewhere))

        let stored = try ThreadStore(directory: rig.directory).load()
        #expect(stored.contains { $0.id == id && $0.allowsEverything })

        try await rig.ask()
        try await waitFor { !rig.model.isRunning }
        #expect(rig.cards.count == 1)
        #expect(rig.cards[0].approval?.decision == .allowEverything)
        #expect(rig.runner.answers.withLock { $0 } == [.allowEverything, .allowOnce])
        #expect(rig.model.approvalWaiters.isEmpty)

        rig.model.resetThreadPermissions(id)
        let cleared = try ThreadStore(directory: rig.directory).load()
        #expect(cleared.contains { $0.id == id && !$0.allowsEverything })
        #expect(!rig.model.isAllowed(bash, in: try #require(rig.model.selectedThread)))

        try await rig.ask()
        try await waitFor { !rig.model.approvalWaiters.isEmpty }
        let waitingID = try #require(rig.model.approvalWaiters.keys.first)
        let again = try #require(rig.cards.first { $0.id == waitingID })
        #expect(again.approval?.decision == nil)
        #expect(again.id != card.id)
        rig.model.stop()
        try await rig.finish()
        #expect(rig.model.threads.first { $0.id == id }?.messages.contains { $0.id == again.id && $0.approval?.decision == .deny } == true)
    }

    @Test func oldThreadsDecodeWithoutAllowEverything() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","createdAt":0,"updatedAt":0,"messages":[],"cursors":[],"sessions":[]}"#
        let thread = try JSONDecoder().decode(DeskThread.self, from: Data(json.utf8))
        #expect(!thread.allowsEverything)
        let text = try #require(String(data: JSONEncoder().encode(thread), encoding: .utf8))
        #expect(!text.contains("allowsEverything"))

        var open = thread
        open.allowsEverything = true
        let back = try JSONDecoder().decode(DeskThread.self, from: JSONEncoder().encode(open))
        #expect(back.allowsEverything)
    }

    @Test func stopDeniesACardThatIsAlreadyWaiting() async throws {
        let rig = try Rig(rule: "Bash(npm:*)")
        try await rig.ask()
        _ = try await rig.waitForCard()
        rig.model.threads[0].allowsEverything = true
        rig.model.stop()
        try await rig.finish()
        #expect(rig.cards.first?.approval?.decision == .deny)
        #expect(rig.runner.answers.withLock { $0 } == [.deny])
    }
}
