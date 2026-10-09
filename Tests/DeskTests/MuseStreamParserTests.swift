import Foundation
import Testing
@testable import Desk

@Test func parserReadsTheCapturedMuseStream() throws {
    let url = try #require(Bundle.module.url(forResource: "muse-stream", withExtension: "jsonl"))
    let text = try String(contentsOf: url, encoding: .utf8)
    var parser = MuseStreamParser()
    var events: [AgentEvent] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        try events.append(contentsOf: parser.events(from: String(line)))
    }

    #expect(sessions(in: events) == ["01a10c7f-cc49-7a20-a540-77cea8a98e96"])
    let reply = replyText(in: events)
    let terminal = try museTerminalText(in: text)
    #expect(reply == terminal)
    #expect(reply.hasPrefix("pelican"))
    #expect(models(in: events) == ["muse-spark-1.3-contributor"])
    #expect(activityEvents(in: events).contains("Using bash"))
    #expect(activityEvents(in: events).first == "Thinking")
    var sawText = false
    var clearedBeforeText = false
    for event in events {
        if case .activity(nil) = event, !sawText {
            clearedBeforeText = true
        }
        if case .text = event {
            sawText = true
        }
    }
    #expect(clearedBeforeText)
    #expect(parser.finishedCleanly)
}

@Test func museCompletedTerminalSuppliesTextWhenNoDeltasArrived() throws {
    var parser = MuseStreamParser()
    let line = #"{"stream":{"kind":"session","id":"s1"},"payload":{"kind":"run_terminal","terminal":"completed","text":"only this"}}"#
    #expect(try parser.events(from: line) == [.session("s1"), .text("only this")])
}

@Test func museFailedTerminalThrowsReasonThenText() {
    var parser = MuseStreamParser()
    #expect(throws: AgentRunError(message: "sandbox denied")) {
        try parser.events(from: #"{"payload":{"kind":"run_terminal","terminal":"failed","reason":"sandbox denied","text":"nope"}}"#)
    }
    #expect(throws: AgentRunError(message: "nope")) {
        try parser.events(from: #"{"payload":{"kind":"run_terminal","terminal":"failed","reason":null,"text":"nope"}}"#)
    }
    #expect(throws: AgentRunError(message: "Muse failed.")) {
        try parser.events(from: #"{"payload":{"kind":"run_terminal","terminal":"cancelled"}}"#)
    }
}

private func museTerminalText(in fixture: String) throws -> String {
    for line in fixture.split(separator: "\n").reversed() {
        guard let object = jsonObject(from: String(line)),
              let payload = object["payload"] as? [String: Any],
              (payload["kind"] as? String) == "run_terminal",
              let text = payload["text"] as? String else {
            continue
        }
        return text
    }
    Issue.record("fixture has no run_terminal text")
    return ""
}

@Test func museFixtureShowsThinkingThenTools() throws {
    var parser = MuseStreamParser()
    let events = try parseFixture("muse-stream", parser: &parser)
    let steps = startedSteps(in: events)
    #expect(steps.first?.kind == .thinking)
    #expect(steps.filter { $0.kind == .command }.count == 2)
    #expect(!steps.contains { $0.title.contains("reminder") || $0.title.contains("model.meta") })
    let finished = finishedSteps(in: events)
    #expect(finished["muse-thinking"] == false)
    for step in steps {
        #expect(finished[step.id] != nil, "step \(step.title) never finished")
    }
}

@Test func museToolStepsFinishOnlyWhenTheTaskEnds() throws {
    var parser = MuseStreamParser()
    let events = try parseFixture("muse-tools-stream", parser: &parser)
    let finished = finishedSteps(in: events)
    let started = startedSteps(in: events)
    #expect(!started.isEmpty)
    #expect(finished.values.allSatisfy { $0 == false }, "\(finished)")
    #expect(started.contains { $0.title == "Ran takibi version" })
    for step in started {
        #expect(finished[step.id] != nil, "step \(step.title) never finished")
    }
}

@Test func museCommandIsReadFromCutOffOutput() {
    #expect(MuseStreamParser.command(inOutput: #"{\n  "chunk_id": "exec-1-1",\n  "command": "takibi tasks get \"Flare\" --json",\n  "exit_"#) == #"takibi tasks get "Flare" --json"#)
    #expect(MuseStreamParser.command(inOutput: #"{"chunk_id": "x"}"#) == nil)
}
