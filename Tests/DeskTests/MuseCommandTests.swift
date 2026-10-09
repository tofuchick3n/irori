import Foundation
import Testing
@testable import Desk

@Test func musePreambleIsOnlyAddedWithoutASession() {
    let prompt = "User: hi"
    let workspace = URL(filePath: "/tmp/desk-ws")
    let preamble = AgentCommand.roundtablePrompt(for: "Muse") + "\n\n" + prompt
    let fresh = MuseCommand.arguments(prompt: prompt, session: nil, workspace: workspace)
    let empty = MuseCommand.arguments(prompt: prompt, session: "", workspace: workspace)
    #expect(fresh == [
        "exec",
        "--json",
        "--provider", "meta",
        "--workspace", "/tmp/desk-ws",
        "--approval-mode", "never",
        preamble,
    ])
    #expect(empty == fresh)
    #expect(fresh.contains("--session-id") == false)

    let resumed = MuseCommand.arguments(prompt: prompt, session: "sess-1", workspace: workspace)
    #expect(resumed == [
        "exec",
        "--json",
        "--provider", "meta",
        "--workspace", "/tmp/desk-ws",
        "--approval-mode", "never",
        "--session-id", "sess-1",
        prompt,
    ])
}

@Test func museArgumentsPassAModelAndOmitAnEmptyOne() {
    let prompt = "User: hi"
    let workspace = URL(filePath: "/tmp/desk-ws")
    let preamble = AgentCommand.roundtablePrompt(for: "Muse") + "\n\n" + prompt
    let selected = MuseCommand.arguments(prompt: prompt, session: nil, workspace: workspace, model: "muse-spark-1.3")
    #expect(selected == [
        "exec",
        "--json",
        "--provider", "meta",
        "--workspace", "/tmp/desk-ws",
        "--approval-mode", "never",
        "--model", "muse-spark-1.3",
        preamble,
    ])
    let resumed = MuseCommand.arguments(prompt: prompt, session: "sess-1", workspace: workspace, model: "muse-spark-1.3")
    #expect(resumed.suffix(5) == ["--model", "muse-spark-1.3", "--session-id", "sess-1", prompt])
    let empty = MuseCommand.arguments(prompt: prompt, session: nil, workspace: workspace, model: "")
    #expect(empty == MuseCommand.arguments(prompt: prompt, session: nil, workspace: workspace))
    #expect(empty.contains("--model") == false)
}

@Test func museCatalogDirectoryIsUnderLocalShare() {
    let home = URL(filePath: "/Users/example")
    var path = MuseCommand.modelCatalogDirectory(home: home).path(percentEncoded: false)
    if path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    #expect(path == "/Users/example/.local/share/muse/model-catalog")
}

@Test func museBinaryCandidatesPreferLocalBin() {
    let home = URL(filePath: "/Users/example")
    #expect(MuseCommand.candidatePaths(home: home) == [
        "/Users/example/.local/bin/muse",
        "/opt/homebrew/bin/muse",
        "/usr/local/bin/muse",
    ])
}
