import Foundation
import Testing
@testable import Desk

func parseFixture<Parser: AgentLineParser>(_ name: String, parser: inout Parser) throws -> [AgentEvent] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
    let text = try String(contentsOf: url, encoding: .utf8)
    var events: [AgentEvent] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        try events.append(contentsOf: parser.events(from: String(line)))
    }
    return events
}

func sessions(in events: [AgentEvent]) -> [String] {
    events.compactMap { event in
        guard case .session(let id) = event else { return nil }
        return id
    }
}

func replyText(in events: [AgentEvent]) -> String {
    events.reduce(into: "") { partial, event in
        guard case .text(let chunk) = event else { return }
        partial += chunk
    }
}

func models(in events: [AgentEvent]) -> [String] {
    events.compactMap { event in
        guard case .model(let id) = event else { return nil }
        return id
    }
}

func activityEvents(in events: [AgentEvent]) -> [String?] {
    var statuses: [String?] = []
    for event in events {
        if case .activity(let status) = event {
            statuses.append(status)
        }
    }
    return statuses
}

func notices(in events: [AgentEvent]) -> [String] {
    events.compactMap { event in
        guard case .notice(let notice) = event else { return nil }
        return notice
    }
}

/// Events with work steps left out; steps carry start times, so tests compare them separately.
func withoutSteps(_ events: [AgentEvent]) -> [AgentEvent] {
    events.filter { event in
        switch event {
        case .stepStarted, .stepFinished: false
        default: true
        }
    }
}

func startedSteps(in events: [AgentEvent]) -> [WorkStep] {
    events.compactMap { event in
        guard case .stepStarted(let step) = event else { return nil }
        return step
    }
}

func finishedSteps(in events: [AgentEvent]) -> [String: Bool] {
    var finished: [String: Bool] = [:]
    for event in events {
        if case .stepFinished(let id, let failed) = event {
            finished[id] = failed
        }
    }
    return finished
}
