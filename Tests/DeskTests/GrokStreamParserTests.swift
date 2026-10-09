import Testing
@testable import Desk

@Test func parserReadsTheCapturedGrokStream() throws {
    var parser = ClaudeStreamParser(agentName: "Grok")
    let events = try parseFixture("grok-stream", parser: &parser)
    #expect(sessions(in: events) == ["01a10c7f-a212-7ce0-843a-05e8d2cddcea"])
    #expect(notices(in: events).isEmpty)
    #expect(replyText(in: events) == """
    I'll run both commands and report what they return.

    pelican

    `takibi version` printed:

    ```
    (node:89802) Warning: The 'NO_COLOR' env is ignored due to the 'FORCE_COLOR' env being set.
    (Use `node --trace-warnings ...` to show where the warning was created)
    takibi-api 0.1.0 · jev wired · via https://app.takibibase.com
    ```

    `touch $HOME/desk-probe-grok` did not work. The command exited with status 1: `touch: /Users/me/desk-probe-grok: Operation not permitted`.
    """)
    #expect(models(in: events) == ["grok-4.7"])
    #expect(activityEvents(in: events).contains("Thinking"))
    #expect(activityEvents(in: events).contains("Using run_terminal_command"))
    #expect(activityEvents(in: events).contains { $0 == nil })
    #expect(parser.sawResult)
}

@Test func grokFixtureShowsThinkingTextAndCommands() throws {
    var parser = ClaudeStreamParser(agentName: "Grok")
    let events = try parseFixture("grok-stream", parser: &parser)
    let steps = startedSteps(in: events)
    let thinking = events.reduce(into: "") { text, event in
        if case .thinking(let chunk) = event { text += chunk }
    }
    #expect(thinking.contains("pelican"))
    #expect(steps.contains { $0.kind == .thinking })
    #expect(steps.contains { $0.title == "Ran takibi version" && $0.kind == .command })
    let finished = finishedSteps(in: events)
    for step in steps {
        #expect(finished[step.id] != nil, "step \(step.title) never finished")
    }
}

@Test func separateThinkingBlocksGetAParagraphBreak() throws {
    var parser = ClaudeStreamParser(agentName: "Grok")
    var thinking = ""
    for line in [
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"First task."}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"thinking"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"thinking_delta","thinking":"I will fetch"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"thinking_delta","thinking":" it."}}}"#,
    ] {
        for case .thinking(let text) in try parser.events(from: line) {
            thinking += text
        }
    }
    #expect(thinking == "First task.\n\nI will fetch it.")
}
