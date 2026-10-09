import Foundation
import Testing
@testable import Desk

@Test func grokArgumentsOmitResumeWithoutAStoredSession() {
    let prompt = "User: hi"
    let workspace = URL(filePath: "/tmp/desk-ws")
    let fresh = GrokCommand.arguments(prompt: prompt, session: nil, workspace: workspace)
    let empty = GrokCommand.arguments(prompt: prompt, session: "", workspace: workspace)
    #expect(fresh == [
        "-p", prompt,
        "--output-format", "streaming-messages-json",
        "--include-partial-messages",
        "--cwd", "/tmp/desk-ws",
        "--sandbox", "workspace",
        "--always-approve",
        "--no-subagents",
        "--rules", AgentCommand.roundtablePrompt(for: "Grok"),
    ])
    #expect(empty == fresh)
    #expect(fresh.contains("--resume") == false)
}

@Test func grokArgumentsResumeOnlyWithAStoredSession() throws {
    let prompt = "User: hi"
    let workspace = URL(filePath: "/tmp/desk-ws")
    let args = GrokCommand.arguments(prompt: prompt, session: "sess-1", workspace: workspace)
    let resume = try #require(args.firstIndex(of: "--resume"))
    #expect(resume == args.count - 2)
    #expect(args[resume + 1] == "sess-1")
    #expect(Array(args.dropLast(2)) == GrokCommand.arguments(prompt: prompt, session: nil, workspace: workspace))
}

@Test func grokArgumentsPassAModelAndOmitAnEmptyOne() throws {
    let prompt = "User: hi"
    let workspace = URL(filePath: "/tmp/desk-ws")
    let selected = GrokCommand.arguments(prompt: prompt, session: "sess-1", workspace: workspace, model: "grok-4")
    let model = try #require(selected.firstIndex(of: "--model"))
    let resume = try #require(selected.firstIndex(of: "--resume"))
    #expect(selected[model + 1] == "grok-4")
    #expect(model < resume)
    #expect(resume == selected.count - 2)
    let unset = GrokCommand.arguments(prompt: prompt, session: nil, workspace: workspace, model: nil)
    let empty = GrokCommand.arguments(prompt: prompt, session: nil, workspace: workspace, model: "")
    #expect(unset.contains("--model") == false)
    #expect(empty == unset)
}

@Test func grokBinaryCandidatesPreferLocalBin() {
    let home = URL(filePath: "/Users/example")
    #expect(GrokCommand.candidatePaths(home: home) == [
        "/Users/example/.local/bin/grok",
        "/opt/homebrew/bin/grok",
        "/usr/local/bin/grok",
    ])
}
