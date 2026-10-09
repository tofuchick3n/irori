import Foundation
import Testing
@testable import Desk

@Test func codexSpeaksAppServerOverStdio() {
    #expect(CodexCommand.arguments() == ["app-server", "--stdio"])
}

@Test func codexThreadStartKeepsWorkspaceWriteAndOmitsAnUnsetModel() throws {
    let workspace = URL(filePath: "/tmp/desk ws")
    let instructions = #"quote " and slash \"#
    let params = CodexCommand.threadStartParams(workspace: workspace, model: nil, instructions: instructions)
    #expect(params["cwd"] as? String == "/tmp/desk ws")
    #expect(params["approvalPolicy"] as? String == "on-request")
    #expect(params["sandbox"] as? String == "workspace-write")
    #expect(params["developerInstructions"] as? String == instructions)
    #expect(params["model"] == nil)
    #expect(params["dynamicTools"] == nil)
    #expect(params["baseInstructions"] == nil)
    #expect(params["sandboxPolicy"] == nil)
    let config = try #require(params["config"] as? [String: Any])
    #expect(config["sandbox_workspace_write.network_access"] as? Bool == true)

    let line = CodexCommand.request(method: "thread/start", id: 2, params: params)
    let object = try #require(jsonObject(from: line))
    let decoded = try #require(object["params"] as? [String: Any])
    #expect(decoded["developerInstructions"] as? String == instructions)
    #expect(object["method"] as? String == "thread/start")
    #expect(object["id"] as? Int == 2)
}

@Test func codexResumeRepeatsTheSafetyModelAndTurnCarriesThePrompt() throws {
    let workspace = URL(filePath: "/tmp/desk-ws")
    let prompt = #"say "hi" and C:\temp"#
    let resume = CodexCommand.threadResumeParams(threadID: "thr-1", workspace: workspace, model: "gpt-5.5")
    #expect(resume["threadId"] as? String == "thr-1")
    #expect(resume["excludeTurns"] as? Bool == true)
    #expect(resume["sandbox"] as? String == "workspace-write")
    #expect(resume["model"] as? String == "gpt-5.5")
    #expect(resume["approvalPolicy"] as? String == "on-request")

    let turn = CodexCommand.turnStartParams(threadID: "thr-1", prompt: prompt, model: "")
    #expect(turn["model"] == nil)
    #expect(turn["summary"] as? String == "concise")
    let input = try #require(turn["input"] as? [[String: Any]])
    #expect(input.count == 1)
    #expect(input[0]["type"] as? String == "text")
    #expect(input[0]["text"] as? String == prompt)
    let elements = try #require(input[0]["text_elements"] as? [Any])
    #expect(elements.isEmpty)

    let line = CodexCommand.request(method: "turn/start", id: 3, params: CodexCommand.turnStartParams(
        threadID: "thr-1",
        prompt: prompt,
        model: "gpt-5.5"
    ))
    let object = try #require(jsonObject(from: line))
    let params = try #require(object["params"] as? [String: Any])
    let decoded = try #require(params["input"] as? [[String: Any]])
    #expect(decoded[0]["text"] as? String == prompt)
    #expect(params["model"] as? String == "gpt-5.5")
}

@Test func codexBinaryCandidatesPreferHomebrew() {
    let home = URL(filePath: "/Users/example")
    #expect(CodexCommand.candidatePaths(home: home) == [
        "/opt/homebrew/bin/codex",
        "/Users/example/.local/bin/codex",
        "/usr/local/bin/codex",
    ])
}
