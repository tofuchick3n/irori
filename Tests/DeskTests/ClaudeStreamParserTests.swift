import Foundation
import Testing
@testable import Desk

@Test func parserReadsTheCapturedClaudeStream() throws {
    let url = try #require(
        Bundle.module.url(forResource: "claude-stream", withExtension: "jsonl")
    )
    let text = try String(contentsOf: url, encoding: .utf8)
    var parser = ClaudeStreamParser()
    var events: [AgentEvent] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        try events.append(contentsOf: parser.events(from: String(line)))
    }

    let sessions = events.compactMap { event -> String? in
        guard case .session(let id) = event else { return nil }
        return id
    }
    let reply = events.reduce(into: "") { partial, event in
        guard case .text(let chunk) = event else { return }
        partial += chunk
    }
    let denials = events.compactMap { event -> AgentEvent? in
        guard case .denied = event else { return nil }
        return event
    }

    #expect(sessions == ["c2f64cee-5210-4e1c-90e2-f6ff64e6072d"])
    #expect(reply == """
    hello roundtable

    I couldn't run `touch /tmp/x`, so `/tmp/x` was not created. `/tmp` is outside this session's working directory, which means the command needs approval. This session is non-interactive, so nobody could approve it and it was denied automatically. Anything else that needs approval will be denied the same way for the rest of this session.

    To make it work, run Claude Code with `/tmp` added as a working directory (for example, `--add-dir /tmp`), allow the command in your permission settings, or run it in an interactive session.

    Separately, four claude.ai connectors need authorizing before they can be used: Basic Memory Cloud, Gmail, Google Calendar and hello_dev. You can do that in your claude.ai connector settings.
    """)
    #expect(denials == [.denied(tool: "Bash", command: "touch /tmp/x")])
    let started = events.compactMap { event -> WorkStep? in
        guard case .stepStarted(let step) = event else { return nil }
        return step
    }
    #expect(started.map(\.title).contains("Ran touch /tmp/x"))
    #expect(started.contains { $0.kind == .thinking })
    #expect(events.contains(.stepFinished(id: "toolu_016w8kndhqwmLcZitfH1aBZk", failed: true)))
    #expect(models(in: events) == ["claude-opus-5-5"])
    #expect(activityEvents(in: events).contains("Thinking"))
    #expect(activityEvents(in: events).contains("Running `touch /tmp/x`"))
    #expect(parser.sawResult)
}

@Test func separateTextBlocksGetABlankLine() throws {
    var parser = ClaudeStreamParser()
    let lines = [
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"one"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"two"}}}"#,
    ]
    var reply = ""
    for line in lines {
        for event in try parser.events(from: line) {
            switch event {
            case .text(let chunk):
                reply += chunk
            case .activity, .stepStarted:
                break
            default:
                Issue.record("unexpected event")
            }
        }
    }
    #expect(reply == "one\n\ntwo")
}

@Test func denialWithoutACommandUsesShortJSON() throws {
    var parser = ClaudeStreamParser()
    let line = #"{"type":"result","is_error":false,"permission_denials":[{"tool_name":"Read","tool_input":{"path":"/tmp/a","mode":"r"}}]}"#
    let events = try parser.events(from: line)
    #expect(events == [.denied(tool: "Read", command: #"{"mode":"r","path":"/tmp/a"}"#)])
}

@Test func errorResultThrowsTheResultText() {
    var parser = ClaudeStreamParser()
    let line = #"{"type":"result","is_error":true,"result":"rate limit"}"#
    #expect(throws: AgentRunError(message: "rate limit")) {
        try parser.events(from: line)
    }
    #expect(parser.sawResult)
}

@Test func nullPermissionDenialsAreNoNotices() throws {
    var parser = ClaudeStreamParser(agentName: "Grok")
    let line = #"{"type":"result","is_error":false,"permission_denials":null}"#
    #expect(try parser.events(from: line) == [])
    #expect(parser.sawResult)
}

@Test func denialNoticeUsesTheAgentName() throws {
    var parser = ClaudeStreamParser(agentName: "Grok")
    let line = #"{"type":"result","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"touch /tmp/x"}}]}"#
    #expect(try parser.events(from: line) == [.denied(tool: "Bash", command: "touch /tmp/x")])
}

@Test func bashRunsAndOtherToolsAreNamed() throws {
    var parser = ClaudeStreamParser()
    let line = #"{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"takibi version"}},{"type":"tool_use","name":"Read","input":{"path":"a"}}]}}"#
    let events = try parser.events(from: line)
    #expect(withoutSteps(events) == [
        .model("claude-sonnet-5-5"),
        .activity("Running `takibi version`"),
        .activity("Using Read"),
    ])
    #expect(startedSteps(in: events).map(\.title) == ["Ran takibi version", "Read a"])
}

@Test func theFirstTextDeltaClearsActivity() throws {
    var parser = ClaudeStreamParser()
    let start = #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking"}}}"#
    let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#
    #expect(try withoutSteps(parser.events(from: start)) == [.activity("Thinking")])
    #expect(try parser.events(from: delta) == [.activity(nil), .text("hi")])
}

@Test func ignoredClaudeLinesProduceNoEvents() throws {
    var parser = ClaudeStreamParser()
    let lines = [
        "",
        "not json",
        #"{"type":"system","subtype":"status","status":"requesting"}"#,
        #"{"type":"rate_limit_event"}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"echo"}]}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}}"#,
    ]
    for line in lines {
        let events = try parser.events(from: line)
        #expect(events.isEmpty)
    }
    #expect(parser.sawResult == false)
}
