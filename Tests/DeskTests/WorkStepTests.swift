import Foundation
import Testing
@testable import Desk

@Test func toolNamesBecomeKindsAndTitles() {
    #expect(WorkStep.tool(id: "1", name: "Bash", input: ["command": "takibi tasks get 1"]).title == "Ran takibi tasks get 1")
    #expect(WorkStep.tool(id: "1", name: "run_terminal_command", input: ["command": "ls"]).kind == .command)
    #expect(WorkStep.tool(id: "1", name: "Write", input: ["file_path": "/w/report.html"]).title == "Wrote report.html")
    #expect(WorkStep.tool(id: "1", name: "Read", input: ["file_path": "/w/notes.md"]).title == "Read notes.md")
    #expect(WorkStep.tool(id: "1", name: "WebSearch", input: nil).title == "Used WebSearch")
    let long = WorkStep.command(id: "1", String(repeating: "a", count: 80) + "\nsecond line")
    #expect(long.title == "Ran " + String(repeating: "a", count: 60) + "…")
    #expect(long.detail?.contains("second line") == true)
}

@Test func runningStepsReadInThePresentTense() {
    var step = WorkStep.command(id: "1", "takibi version")
    #expect(step.liveTitle == "Running takibi version")
    step.state = .done
    #expect(step.liveTitle == "Ran takibi version")
    #expect(WorkStep.fileWrite(id: "2", path: "a.md").liveTitle == "Writing a.md")
    #expect(WorkStep.thinking(id: "3").liveTitle == "Thinking")
}

@Test func grokReadsAndSkillsAreNamed() {
    #expect(WorkStep.tool(id: "1", name: "read_file", input: ["target_file": "/w/brief.md"]).title == "Read brief.md")
    #expect(WorkStep.tool(id: "1", name: "read_file", input: ["target_file": "/Users/me/.grok/skills/takibi-use/SKILL.md"]).title == "Read the takibi-use skill")
    #expect(WorkStep.tool(id: "1", name: "read_skill", input: nil).title == "Read a skill")
}

@Test func codexShellWrapperIsDropped() {
    #expect(WorkStep.command(id: "1", "/bin/zsh -lc 'takibi version'").title == "Ran takibi version")
    #expect(WorkStep.command(id: "1", #"/bin/zsh -lc "printf 'heron\\n' > out.md""#).title == #"Ran printf 'heron\n' > out.md"#)
    #expect(WorkStep.command(id: "1", "takibi version").title == "Ran takibi version")
    #expect(WorkStep.tool(id: "1", name: "search_replace", input: ["file_path": "/w/out.md"]).title == "Wrote out.md")
}

@MainActor
@Test func modelRecordsStepsThinkingTimingAndFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-m10-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = DeskModel(store: ThreadStore(directory: directory), runner: StepRunner(), defaults: UserDefaults(suiteName: "desk-m10-\(UUID().uuidString)")!)
    model.newThread()
    model.draft = "hi"
    model.send()
    for _ in 0..<300 where model.isRunning {
        try await Task.sleep(for: .milliseconds(10))
    }
    let reply = try #require(model.selectedThread?.messages.last { if case .agent = $0.author { true } else { false } })
    #expect(reply.thinking == "Let me look.")
    #expect(reply.steps.map(\.title) == ["Thinking", "Ran takibi version", "Wrote out.md"])
    #expect(reply.steps.map(\.state) == [.done, .failed, .done])
    #expect(reply.steps.allSatisfy { $0.endedAt != nil })
    #expect(reply.startedAt != nil && reply.finishedAt != nil)
    #expect(reply.files == ["out.md"])
    let notice = try #require(model.selectedThread?.messages.last)
    #expect(notice.body.hasSuffix(" was refused jq."), "\(notice.body)")
    #expect(notice.deniedPrograms == ["jq"])

    model.allowCommand("jq")
    model.allowCommand("jq")
    #expect(model.allowedCommands.filter { $0 == "jq" }.count == 1)
}

@MainActor
@Test func stoppingMarksRunningStepsFailed() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "desk-m10-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = DeskModel(store: ThreadStore(directory: directory), runner: StuckStepRunner(), defaults: UserDefaults(suiteName: "desk-m10-\(UUID().uuidString)")!)
    model.newThread()
    model.draft = "hi"
    model.send()
    for _ in 0..<100 {
        if model.selectedThread?.messages.last?.steps.isEmpty == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    model.stop()
    for _ in 0..<300 where model.isRunning {
        try await Task.sleep(for: .milliseconds(10))
    }
    let reply = try #require(model.selectedThread?.messages.last)
    #expect(reply.steps.map(\.state) == [.failed])
    #expect(reply.finishedAt != nil)
}

private struct StepRunner: AgentRunner {
    func run(agent _: AgentID, prompt _: String, session _: String?, workspace: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.stepStarted(.thinking(id: "t")))
            continuation.yield(.thinking("Let me look."))
            continuation.yield(.stepFinished(id: "t", failed: false))
            continuation.yield(.stepStarted(.command(id: "c", "takibi version")))
            continuation.yield(.stepFinished(id: "c", failed: true))
            continuation.yield(.stepStarted(.fileWrite(id: "w", path: "out.md")))
            try? "report".write(to: workspace.appending(path: "out.md"), atomically: true, encoding: .utf8)
            continuation.yield(.text("Done."))
            continuation.yield(.denied(tool: "Bash", command: "takibi x | jq ."))
            continuation.finish()
        }
    }
}

private struct StuckStepRunner: AgentRunner {
    func run(agent _: AgentID, prompt _: String, session _: String?, workspace _: URL, model _: String?, effort _: String? = nil, permissions _: AgentPermissions = .standard, executable _: URL? = nil, approve _: @escaping ApprovalHandler = { _ in .deny }) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.text("Partial"))
                continuation.yield(.stepStarted(.command(id: "c", "sleep 100")))
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
