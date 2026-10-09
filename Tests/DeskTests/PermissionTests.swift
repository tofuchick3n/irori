import Foundation
import Testing
@testable import Desk

@Test func claudePermissionsMapWritesAndCommands() throws {
    let writesOn = ClaudeCommand.arguments(session: nil,
        allowsFileWrites: true,
        allowedCommands: ["takibi", "git"]
    )
    #expect(writesOn.containsSequence(["--permission-mode", "acceptEdits"]))
    #expect(writesOn.containsSequence(["--allowedTools", "Bash(takibi:*)"]))
    #expect(writesOn.containsSequence(["--allowedTools", "Bash(git:*)"]))
    let takibi = try #require(writesOn.firstIndex(of: "Bash(takibi:*)"))
    let git = try #require(writesOn.firstIndex(of: "Bash(git:*)"))
    #expect(takibi < git)

    let writesOff = ClaudeCommand.arguments(session: nil,
        allowsFileWrites: false,
        allowedCommands: []
    )
    #expect(writesOff.containsSequence(["--permission-mode", "default"]))
    #expect(!writesOff.contains("--allowedTools"))
    #expect(!writesOff.contains("--permission-prompts"))

    let skipped = ClaudeCommand.arguments(session: nil,
        allowsFileWrites: false,
        allowedCommands: [" git ", "", "   "]
    )
    #expect(skipped.containsSequence(["--permission-mode", "default"]))
    #expect(skipped.filter { $0 == "--allowedTools" }.count == 1)
    #expect(skipped.contains("Bash(git:*)"))
    #expect(!skipped.contains("Bash( :*)"))
}

@Test func grokPermissionsMapTheSandbox() {
    let workspace = URL(filePath: "/tmp/desk-ws")
    let on = GrokCommand.arguments(prompt: "hi", session: nil, workspace: workspace, allowsFileWrites: true)
    let off = GrokCommand.arguments(prompt: "hi", session: nil, workspace: workspace, allowsFileWrites: false)
    #expect(on.containsSequence(["--sandbox", "workspace"]))
    #expect(off.containsSequence(["--sandbox", "read-only"]))
}

@Test func musePermissionsDisableWritesAndShellOnlyWhenWritesAreOff() throws {
    let workspace = URL(filePath: "/tmp/desk-ws")
    let on = MuseCommand.arguments(prompt: "hi", session: nil, workspace: workspace, allowsFileWrites: true)
    let off = MuseCommand.arguments(prompt: "hi", session: nil, workspace: workspace, allowsFileWrites: false)
    #expect(!on.contains("--disable-write"))
    #expect(!on.contains("--disable-shell"))
    #expect(off.contains("--disable-shell"))
    #expect(off.last == MuseCommand.arguments(prompt: "hi", session: nil, workspace: workspace, allowsFileWrites: true).last)
    let approval = try #require(off.firstIndex(of: "never"))
    let disable = try #require(off.firstIndex(of: "--disable-write"))
    #expect(off[approval - 1] == "--approval-mode")
    #expect(disable == approval + 1)
    #expect(off.last == on.last)
}

@Test func codexPermissionsMapSandboxAndNetwork() {
    let workspace = URL(filePath: "/tmp/desk-ws")
    let on = CodexCommand.threadStartParams(workspace: workspace, model: nil, allowsFileWrites: true)
    #expect(on["sandbox"] as? String == "workspace-write")
    #expect((on["config"] as? [String: Any])?["sandbox_workspace_write.network_access"] as? Bool == true)
    #expect((on["config"] as? [String: Any])?["approvals_reviewer"] as? String == "user")

    let off = CodexCommand.threadStartParams(workspace: workspace, model: "gpt", allowsFileWrites: false)
    #expect(off["sandbox"] as? String == "read-only")
    #expect((off["config"] as? [String: Any])?.keys.sorted() == ["approvals_reviewer"])
    #expect(off["model"] as? String == "gpt")

    let resume = CodexCommand.threadResumeParams(threadID: "thr", workspace: workspace, model: nil, allowsFileWrites: false)
    #expect(resume["sandbox"] as? String == "read-only")
    #expect((resume["config"] as? [String: Any])?.keys.sorted() == ["approvals_reviewer"])
    #expect(resume["threadId"] as? String == "thr")
}

@Test func codexSessionWritesReadOnlyWithoutNetworkConfig() throws {
    let stdin = AgentStdin()
    var session = CodexAppServerSession(
        stdin: stdin,
        prompt: "User: hi",
        session: "thr-old",
        workspace: URL(filePath: "/tmp/desk-ws"),
        model: nil,
        allowsFileWrites: false
    )
    session.sessionStarted()
    _ = try session.events(from: #"{"id":1,"result":{}}"#)
    let resume = try #require(jsonObject(from: stdin.writtenLines().last ?? ""))
    #expect(resume["method"] as? String == "thread/resume")
    let params = try #require(resume["params"] as? [String: Any])
    #expect(params["sandbox"] as? String == "read-only")
    #expect((params["config"] as? [String: Any])?.keys.sorted() == ["approvals_reviewer"])

    let fresh = AgentStdin()
    var started = CodexAppServerSession(
        stdin: fresh,
        prompt: "User: hi",
        session: nil,
        workspace: URL(filePath: "/tmp/desk-ws"),
        model: nil,
        allowsFileWrites: false
    )
    started.sessionStarted()
    _ = try started.events(from: #"{"id":1,"result":{}}"#)
    let thread = try #require(jsonObject(from: fresh.writtenLines().last ?? ""))
    let start = try #require(thread["params"] as? [String: Any])
    #expect(thread["method"] as? String == "thread/start")
    #expect(start["sandbox"] as? String == "read-only")
    #expect((start["config"] as? [String: Any])?.keys.sorted() == ["approvals_reviewer"])
}

@Test func deniedProgramsSkipAllowedOnesAndAssignments() {
    let command = #"takibi tasks get 2f87 --json | python3 -c "import json" && FOO=1 /usr/bin/jq . ; takibi version"#
    #expect(DeniedCommand.programs(in: command, allowed: ["takibi"]) == ["python3", "jq"])
    #expect(DeniedCommand.programs(in: "touch /tmp/x", allowed: ["takibi"]) == ["touch"])
    #expect(DeniedCommand.programs(in: "takibi version", allowed: ["takibi"]) == [])
}

@Test func deniedNoticeNamesTheRefusedPrograms() {
    let notice = DeskModel.deniedNotice(agent: .claude, tool: "Bash", command: "takibi x | python3 -c 1", allowed: ["takibi"])
    #expect(notice.body == "Claude was refused python3.")
    #expect(notice.deniedPrograms == ["python3"])
    #expect(notice.deniedCommand == "takibi x | python3 -c 1")
    let write = DeskModel.deniedNotice(agent: .claude, tool: "Write", command: #"{"file_path":"/tmp/a"}"#, allowed: ["takibi"])
    #expect(write.body == "Claude was refused Write.")
    #expect(write.deniedPrograms.isEmpty)
}

private extension Array where Element: Equatable {
    func containsSequence(_ needle: [Element]) -> Bool {
        guard needle.count <= count else { return false }
        return (0...(count - needle.count)).contains { start in
            self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}
