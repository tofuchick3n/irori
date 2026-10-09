import Darwin
import Foundation
import Testing
@testable import Desk

@Test func cancellingTheAgentProcessKillsBackgroundChildren() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "desk-pgroup-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appending(path: "agent", directoryHint: .notDirectory)
    let source = """
    #!/bin/bash
    set +m
    sleep 300 &
    echo $!
    echo $! > sleep.pid
    wait
    """
    try Data(source.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

    let workspace = root.appending(path: "work", directoryHint: .isDirectory)
    let stream = AgentProcess(
        label: "stand-in",
        executable: script,
        candidates: [],
        arguments: [],
        environment: AgentCommand.environment(),
        workspace: workspace,
        notFound: "stand-in was not found."
    ).run { IgnoringParser() }
    let reader = Task {
        for try await _ in stream {}
    }
    defer { reader.cancel() }

    let sleepPID = try await waitForSleepPID(in: workspace)
    defer {
        if Darwin.kill(sleepPID, 0) == 0 {
            Darwin.kill(sleepPID, SIGKILL)
        }
    }

    reader.cancel()

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    var gone = false
    while clock.now < deadline {
        if Darwin.kill(sleepPID, 0) != 0 {
            gone = true
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(gone)

    let readerFinished = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = await reader.result
            return true
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        return finished
    }
    #expect(readerFinished)
}

private func waitForSleepPID(in workspace: URL) async throws -> pid_t {
    let pidFile = workspace.appending(path: "sleep.pid", directoryHint: .notDirectory)
    for _ in 0..<100 {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 1,
           Darwin.kill(pid, 0) == 0 {
            return pid
        }
        try await Task.sleep(for: .milliseconds(30))
    }
    Issue.record("the stand-in agent did not print a sleep pid")
    throw AgentRunError(message: "the stand-in agent did not print a sleep pid")
}

private struct IgnoringParser: AgentLineParser {
    var finishedCleanly: Bool { false }

    mutating func events(from _: String) throws -> [AgentEvent] { [] }
}
/// posix_spawn keeps the parent's blocked signals and ignored dispositions.
/// A child that inherits an ignored SIGCHLD or SIGTERM can't wait for its own
/// helpers and won't stop on SIGTERM, which hung Grok on exit.
@Test func agentProcessStartsWithDefaultSignals() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "desk-sigmask-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appending(path: "agent", directoryHint: .notDirectory)
    try Data(#"""
    #!/usr/bin/perl
    use POSIX qw(sigprocmask SIG_BLOCK);
    my $mask = POSIX::SigSet->new;
    sigprocmask(SIG_BLOCK, POSIX::SigSet->new, $mask);
    my $blocked = grep { $mask->ismember($_) } 1 .. 31;
    print join(",", (map { $SIG{$_} // "DEFAULT" } qw(TERM CHLD INT HUP PIPE)), $blocked);
    """#.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

    let stream = AgentProcess(
        label: "stand-in",
        executable: script,
        candidates: [],
        arguments: [],
        environment: AgentCommand.environment(),
        workspace: root.appending(path: "work", directoryHint: .isDirectory),
        notFound: "stand-in was not found."
    ).run { EchoingParser() }

    var output = ""
    for try await event in stream {
        if case .text(let line) = event { output += line }
    }
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "DEFAULT,DEFAULT,DEFAULT,DEFAULT,DEFAULT,0")
}

private struct EchoingParser: AgentLineParser {
    var finishedCleanly: Bool { true }

    mutating func events(from line: String) throws -> [AgentEvent] { [.text(line)] }
}

/// Grok once finished its turn and then never exited. A turn must end shortly
/// after the final result even if the CLI keeps running.
@Test func agentProcessEndsTheTurnSoonAfterTheResult() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "desk-linger-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appending(path: "agent", directoryHint: .notDirectory)
    try Data("#!/bin/bash\necho reply\necho DONE\nexec sleep 300\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

    let stream = AgentProcess(
        label: "stand-in",
        executable: script,
        candidates: [],
        arguments: [],
        environment: AgentCommand.environment(),
        workspace: root.appending(path: "work", directoryHint: .isDirectory),
        notFound: "stand-in was not found."
    ).run { DoneParser() }

    let clock = ContinuousClock()
    let started = clock.now
    var texts: [String] = []
    for try await event in stream {
        if case .text(let line) = event { texts.append(line) }
    }
    #expect(texts == ["reply"])
    #expect(clock.now - started < .seconds(8))
}

@Test func exitZeroWithoutAFinalReplyIsAnError() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "desk-no-reply-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appending(path: "agent", directoryHint: .notDirectory)
    try Data("#!/bin/bash\necho hello\nexit 0\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

    let stream = AgentProcess(
        label: "stand-in",
        executable: script,
        candidates: [],
        arguments: [],
        environment: AgentCommand.environment(),
        workspace: root.appending(path: "work", directoryHint: .isDirectory),
        notFound: "stand-in was not found."
    ).run { IgnoringParser() }

    do {
        for try await _ in stream {}
        Issue.record("expected the run to fail")
    } catch let error as AgentRunError {
        #expect(error == AgentRunError(message: "stand-in ended without a final reply."))
    }
}

@Test func waitForExitDoesNotTreatAWaitFailureAsStatusZero() async {
    #expect(await waitForExit(pid_t(Int32.max)) == nil)
}

private struct DoneParser: AgentLineParser {
    private(set) var finishedCleanly = false

    mutating func events(from line: String) throws -> [AgentEvent] {
        if line == "DONE" {
            finishedCleanly = true
            return []
        }
        return [.text(line)]
    }
}

@Test func quittingEndsRunningAgentGroups() async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/perl")
    process.arguments = ["-e", "setpgrp(0, 0); exec 'sleep', 30"]
    try process.run()
    let pid = process.processIdentifier
    for _ in 0..<50 where getpgid(pid) != pid {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(getpgid(pid) == pid)
    let groups = AgentProcessGroups()
    groups.insert(pid)
    groups.terminateAll(grace: 2)
    process.waitUntilExit()
    #expect(Darwin.kill(-pid, 0) != 0)
}
