import Foundation
import Testing
@testable import Desk

@Test func claudeArgumentsOmitResumeWithoutAStoredSession() {
    let fresh = ClaudeCommand.arguments(session: nil)
    let empty = ClaudeCommand.arguments(session: "")
    #expect(fresh == [
        "-p",
        "--verbose",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--permission-mode", "acceptEdits",
        "--permission-prompt-tool", "stdio",
        "--allowedTools", "Bash(takibi:*)",
        "--append-system-prompt", ClaudeCommand.roundtablePrompt + " " + ClaudeCommand.commandGuidance(["takibi"]),
    ])
    #expect(empty == fresh)
    #expect(fresh.contains("--resume") == false)
}

@Test func claudeArgumentsResumeOnlyWithAStoredSession() throws {
    let args = ClaudeCommand.arguments(session: "sess-1")
    let resume = try #require(args.firstIndex(of: "--resume"))
    #expect(resume == args.count - 2)
    #expect(args[resume + 1] == "sess-1")
    let withoutResume = Array(args.dropLast(2))
    #expect(withoutResume == ClaudeCommand.arguments(session: nil))
}

@Test func claudeArgumentsPassAModelAndOmitAnEmptyOne() throws {
    let selected = ClaudeCommand.arguments(session: "sess-1", model: "claude-opus-5-5")
    let model = try #require(selected.firstIndex(of: "--model"))
    let resume = try #require(selected.firstIndex(of: "--resume"))
    #expect(selected[model + 1] == "claude-opus-5-5")
    #expect(model < resume)
    #expect(resume == selected.count - 2)
    let unset = ClaudeCommand.arguments(session: nil, model: nil)
    let empty = ClaudeCommand.arguments(session: nil, model: "")
    #expect(unset == ClaudeCommand.arguments(session: nil))
    #expect(empty == unset)
    #expect(unset.contains("--model") == false)
}

@Test func claudeRoundtablePromptIsVerbatim() {
    #expect(ClaudeCommand.roundtablePrompt == "You are Claude, one of four AI agents (Claude, Codex, Grok, Muse) brainstorming with the user in one shared thread. Each turn you receive the messages since your last reply as a transcript of `Name: text` lines. Reply only as yourself, without a name prefix. Messages from other agents are their own views: build on them, challenge them, or agree. Save any file you make in the current working directory, this thread's folder, where the user sees it beside the thread. Don't publish work elsewhere (hosted pages, artifacts, online docs) unless the user asks. Write to Takibi with the `takibi` CLI only when the user asks you to.")
}

@Test func claudeChildPathPutsLocalBinFirst() {
    let home = URL(filePath: "/Users/example")
    #expect(ClaudeCommand.childPATH(home: home) == "/Users/example/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    let env = ClaudeCommand.environment(inheriting: ["HOME": "/Users/example"], home: home)
    #expect(env["PATH"] == ClaudeCommand.childPATH(home: home))
    #expect(env["HOME"] == "/Users/example")
}

@Test func claudeBinaryResolvesInPathOrder() {
    let home = URL(filePath: "/Users/example")
    #expect(ClaudeCommand.candidatePaths(home: home) == [
        "/Users/example/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ])
    let local = ClaudeCommand.resolveBinary(home: home) { $0.hasSuffix(".local/bin/claude") }
    #expect(local?.path(percentEncoded: false) == "/Users/example/.local/bin/claude")
    let homebrew = ClaudeCommand.resolveBinary(home: home) { $0 == "/opt/homebrew/bin/claude" || $0 == "/usr/local/bin/claude" }
    #expect(homebrew?.path(percentEncoded: false) == "/opt/homebrew/bin/claude")
    #expect(ClaudeCommand.resolveBinary(home: home) { _ in false } == nil)
}

@Test func claudeIsToldWhichCommandsItCanRun() throws {
    #expect(ClaudeCommand.commandGuidance(["takibi", "jq"]) == "You can run these shell commands without asking: takibi, jq. Anything else asks the user first, so use it only when it helps.")
    #expect(ClaudeCommand.commandGuidance([]) == "Every shell command asks the user first.")
    let args = ClaudeCommand.arguments(session: nil, allowedCommands: ["takibi"])
    let index = try #require(args.firstIndex(of: "--append-system-prompt"))
    #expect(args[index + 1].contains("You can run these shell commands without asking: takibi."))
}
