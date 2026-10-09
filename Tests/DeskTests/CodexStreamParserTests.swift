import Foundation
import Testing
@testable import Desk

@Test func parserReadsTheCapturedCodexStream() throws {
    var parser = CodexStreamParser()
    let events = try parseFixture("codex-stream", parser: &parser)
    #expect(sessions(in: events) == ["01a10c7f-1b03-7071-b44c-9b4eaf80222a"])
    #expect(replyText(in: events) == """
    pelican

    `takibi version` reported: `takibi-api 0.1.0 · jev wired · via https://app.takibibase.com`

    `touch $HOME/desk-probe-codex` failed: `Operation not permitted`.
    """)
}

@Test func codexTurnFailureThrowsTheErrorMessage() {
    var parser = CodexStreamParser()
    let line = #"{"type":"turn.failed","error":{"message":"sandbox denied"}}"#
    #expect(throws: AgentRunError(message: "sandbox denied")) {
        try parser.events(from: line)
    }
}

@Test func codexErrorLineThrowsTheMessage() {
    var parser = CodexStreamParser()
    let line = #"{"type":"error","message":"boom"}"#
    #expect(throws: AgentRunError(message: "boom")) {
        try parser.events(from: line)
    }
}

@Test func ignoredCodexLinesProduceNoEvents() throws {
    var parser = CodexStreamParser()
    let lines = [
        "",
        "not json",
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"takibi version"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"takibi version","exit_code":0}}"#,
    ]
    for line in lines {
        #expect(try parser.events(from: line).isEmpty)
    }
}
