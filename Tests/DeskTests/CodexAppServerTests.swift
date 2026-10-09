import Foundation
import Testing
@testable import Desk

@Test func codexAppServerStreamsATurnFromHandWrittenLines() throws {
    let stdin = AgentStdin()
    var session = CodexAppServerSession(
        stdin: stdin,
        prompt: "User: hi",
        session: nil,
        workspace: URL(filePath: "/tmp/desk-ws"),
        model: "gpt-5.5"
    )
    session.sessionStarted()
    var events: [AgentEvent] = []
    events += try session.events(from: #"{"id":1,"result":{"userAgent":"test"}}"#)
    events += try session.events(from: #"{"id":2,"result":{"thread":{"id":"thr-1","model":"gpt-5.5"},"model":"gpt-5.5"}}"#)
    events += try session.events(from: #"{"method":"item/started","params":{"item":{"id":"reason-1","type":"reasoning"}}}"#)
    events += try session.events(from: #"{"method":"item/agentMessage/delta","params":{"delta":"Hello"}}"#)
    events += try session.events(from: #"{"method":"item/started","params":{"item":{"id":"cmd-1","type":"commandExecution","command":"takibi version"}}}"#)
    events += try session.events(from: #"{"method":"item/completed","params":{"item":{"id":"msg-1","type":"agentMessage","text":"Hello"}}}"#)
    events += try session.events(from: #"{"method":"turn/completed","params":{"turn":{}}}"#)

    #expect(withoutSteps(events) == [
        .session("thr-1"),
        .model("gpt-5.5"),
        .activity("Thinking"),
        .text("Hello"),
        .activity("Running `takibi version`"),
    ])
    #expect(session.finishedCleanly)
    #expect(methods(in: stdin.writtenLines()) == ["initialize", "initialized", "thread/start", "turn/start"])

    let thread = try #require(jsonObject(from: stdin.writtenLines()[2]))
    let params = try #require(thread["params"] as? [String: Any])
    #expect(params["sandbox"] as? String == "workspace-write")
    #expect(params["model"] as? String == "gpt-5.5")
    #expect((params["config"] as? [String: Any])?["sandbox_workspace_write.network_access"] as? Bool == true)
}

@Test func codexResumeSendsTheStoredThreadAndAMissingRolloutIsAMissingSession() throws {
    let stdin = AgentStdin()
    var session = CodexAppServerSession(
        stdin: stdin,
        prompt: "User: hi",
        session: "thr-old",
        workspace: URL(filePath: "/tmp/desk-ws"),
        model: nil
    )
    session.sessionStarted()
    _ = try session.events(from: #"{"id":1,"result":{}}"#)
    let resume = try #require(jsonObject(from: stdin.writtenLines().last ?? ""))
    #expect(resume["method"] as? String == "thread/resume")
    let params = try #require(resume["params"] as? [String: Any])
    #expect(params["threadId"] as? String == "thr-old")
    #expect(params["excludeTurns"] as? Bool == true)
    #expect(params["model"] == nil)
    #expect(params["sandbox"] as? String == "workspace-write")

    #expect(throws: AgentRunError(message: "no rollout found for thread id thr-old", missingSession: true)) {
        try session.events(from: #"{"id":2,"error":{"code":-32000,"message":"no rollout found for thread id thr-old"}}"#)
    }
}

@Test func codexRejectsServerRequestsAndFallsBackToACompletedMessage() throws {
    let stdin = AgentStdin()
    var session = CodexAppServerSession(
        stdin: stdin,
        prompt: "User: hi",
        session: nil,
        workspace: URL(filePath: "/tmp/desk-ws"),
        model: nil
    )
    let denied = try session.events(from: #"{"method":"item/tool/call","id":0,"params":{"tool":"get_attached_task"}}"#)
    #expect(denied == [.notice("Codex asked for item/tool/call. \(Brand.name) denied it.")])
    let response = try #require(jsonObject(from: stdin.writtenLines().last ?? ""))
    #expect(response["id"] as? Int == 0)
    let error = try #require(response["error"] as? [String: Any])
    #expect(error["code"] as? Int == -32601)
    #expect(error["message"] as? String == CodexCommand.rejectedRequestMessage)

    let text = try session.events(from: #"{"method":"item/completed","params":{"item":{"id":"msg-1","type":"agentMessage","text":"only this"}}}"#)
    #expect(text == [.text("only this")])
    let again = try session.events(from: #"{"method":"item/completed","params":{"item":{"id":"msg-1","type":"agentMessage","text":"only this"}}}"#)
    #expect(again.isEmpty)
    let later = try session.events(from: #"{"method":"item/completed","params":{"item":{"id":"msg-2","type":"agent_message","text":"second"}}}"#)
    #expect(later == [.text("\n\nsecond")])
}

@Test func codexTurnFailureThrows() {
    var session = CodexAppServerSession(
        stdin: AgentStdin(),
        prompt: "User: hi",
        session: nil,
        workspace: URL(filePath: "/tmp/desk-ws"),
        model: nil
    )
    #expect(throws: AgentRunError(message: "sandbox denied")) {
        try session.events(from: #"{"method":"turn/completed","params":{"turn":{"error":{"message":"sandbox denied"}}}}"#)
    }
    #expect(session.finishedCleanly == false)
    #expect(throws: AgentRunError(message: "boom")) {
        try session.events(from: #"{"method":"turn/failed","params":{"error":{"message":"boom"}}}"#)
    }
}

@Test func codexModelListReadsIdOrModelAndSkipsHidden() {
    let result: [String: Any] = [
        "data": [
            ["model": "gpt-5.5", "displayName": "GPT-5.5", "isDefault": true, "hidden": false],
            ["id": "gpt-hidden", "displayName": "Hidden", "hidden": true],
            ["model": "gpt-5.5", "displayName": "duplicate"],
            ["displayName": "nameless"],
        ],
    ]
    #expect(ModelLists.parseCodexModelList(result) == [
        AgentModelOption(id: "gpt-5.5", label: "GPT-5.5", isDefault: true),
    ])
}

private func methods(in lines: [String]) -> [String] {
    lines.compactMap { jsonObject(from: $0)?["method"] as? String }
}

@Test func codexAppServerIgnoresErrorsForRequestsDeskDidNotSend() throws {
    let stdin = AgentStdin()
    var session = CodexAppServerSession(
        stdin: stdin,
        prompt: "User: hi",
        session: nil,
        workspace: URL(filePath: "/tmp/desk-ws"),
        model: nil
    )
    session.sessionStarted()
    _ = try session.events(from: #"{"id":1,"result":{"userAgent":"test"}}"#)
    _ = try session.events(from: #"{"id":2,"result":{"thread":{"id":"thr-1"}}}"#)
    let events = try session.events(from: #"{"id":99,"error":{"code":-32601,"message":"unrelated"}}"#)
    #expect(events.isEmpty)
    #expect(throws: AgentRunError.self) {
        _ = try session.events(from: #"{"id":3,"error":{"code":-32000,"message":"turn failed"}}"#)
    }
}

@Test func codexItemsBecomeSteps() throws {
    let stdin = AgentStdin()
    var session = CodexAppServerSession(stdin: stdin, prompt: "User: hi", session: nil, workspace: URL(filePath: "/tmp/desk-ws"), model: nil)
    session.sessionStarted()
    var events: [AgentEvent] = []
    events += try session.events(from: #"{"id":1,"result":{}}"#)
    events += try session.events(from: #"{"id":2,"result":{"thread":{"id":"thr-1"}}}"#)
    events += try session.events(from: #"{"method":"item/started","params":{"item":{"id":"r1","type":"reasoning"}}}"#)
    events += try session.events(from: #"{"method":"item/reasoning/summaryTextDelta","params":{"itemId":"r1","delta":"Checking the card"}}"#)
    events += try session.events(from: #"{"method":"item/completed","params":{"item":{"id":"r1","type":"reasoning"}}}"#)
    events += try session.events(from: #"{"method":"item/started","params":{"item":{"id":"c1","type":"commandExecution","command":"takibi tasks list"}}}"#)
    events += try session.events(from: #"{"method":"item/completed","params":{"item":{"id":"c1","type":"commandExecution","status":"completed","exitCode":2}}}"#)
    events += try session.events(from: #"{"method":"item/started","params":{"item":{"id":"f1","type":"fileChange","changes":[{"path":"/tmp/desk-ws/a.md"},{"path":"/tmp/desk-ws/b.md"}]}}}"#)
    events += try session.events(from: #"{"method":"item/completed","params":{"item":{"id":"f1","type":"fileChange","status":"completed","changes":[{"path":"/tmp/desk-ws/a.md"},{"path":"/tmp/desk-ws/b.md"}]}}}"#)

    #expect(events.contains(.thinking("Checking the card")))
    #expect(startedSteps(in: events).map(\.title) == ["Thinking", "Ran takibi tasks list", "Wrote a.md", "Wrote b.md"])
    #expect(finishedSteps(in: events) == ["r1": false, "c1": true, "f1": false, "f1-1": false])
    #expect(CodexAppServerSession.changedPaths(["changes": ["x.md": [:], "a.md": [:]]]) == ["a.md", "x.md"])
}

@Test func codexReasoningSummariesAreSeparateParagraphs() throws {
    var session = CodexAppServerSession(stdin: AgentStdin(), prompt: "User: hi", session: nil, workspace: URL(filePath: "/tmp/desk-ws"), model: nil)
    session.sessionStarted()
    func delta(_ item: String, _ index: Int, _ text: String) throws -> [AgentEvent] {
        try session.events(from: #"{"method":"item/reasoning/summaryTextDelta","params":{"itemId":"\#(item)","summaryIndex":\#(index),"delta":"\#(text)"}}"#)
    }
    var events = try delta("r1", 0, "**Preparing")
    events += try delta("r1", 0, " update**")
    events += try delta("r1", 1, "**Finalizing**")
    events += try delta("r2", 0, "**Validating**")
    #expect(events == [.thinking("**Preparing"), .thinking(" update**"), .thinking("\n\n**Finalizing**"), .thinking("\n\n**Validating**")])
}

@MainActor @Test func savedThinkingShowsTitlesOnTheirOwnLines() {
    let shown = WorkLogView.inlineMarkdown("**Preparing update****Finalizing approach**")
    #expect(String(shown.characters) == "Preparing update\n\nFinalizing approach")
}

@Test func codexMessagesAreSeparateParagraphs() throws {
    var session = CodexAppServerSession(stdin: AgentStdin(), prompt: "User: hi", session: nil, workspace: URL(filePath: "/tmp/desk-ws"), model: nil)
    var text = ""
    for line in [
        #"{"method":"item/agentMessage/delta","params":{"itemId":"m1","delta":"I'll run it."}}"#,
        #"{"method":"item/agentMessage/delta","params":{"itemId":"m2","delta":"Done"}}"#,
        #"{"method":"item/agentMessage/delta","params":{"itemId":"m2","delta":": heron."}}"#,
        #"{"method":"item/completed","params":{"item":{"id":"m3","type":"agentMessage","text":"Also saved."}}}"#,
    ] {
        for case .text(let chunk) in try session.events(from: line) {
            text += chunk
        }
    }
    #expect(text == "I'll run it.\n\nDone: heron.\n\nAlso saved.")
}
