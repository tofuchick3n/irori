import AppKit
import Foundation
import Synchronization

/// Account detail is present only when the CLI reported one.
enum SignInState: Equatable, Sendable {
    case signedIn(String?)
    case signedOut
    case unknown
}

struct SignInOutput: Sendable, Equatable {
    var stdout: String
    var exitCode: Int32
    /// Codex prints its login status here, not on stdout.
    var stderr: String = ""
}

enum SignInCommand {
    static func checkArguments(for agent: AgentID) -> [String] {
        switch agent {
        case .claude: ["auth", "status"]
        case .codex: ["login", "status"]
        case .grok: ["models"]
        case .muse: []
        }
    }

    static func loginArguments(for agent: AgentID) -> [String] {
        switch agent {
        case .claude: ["auth", "login"]
        case .codex, .grok, .muse: ["login"]
        }
    }
}

enum SignInStatus {
    static func claude(from stdout: String) -> SignInState {
        if let object = jsonObject(from: stdout) {
            return claude(object)
        }
        var line = ""
        for character in stdout {
            if character.isNewline {
                if let object = jsonObject(from: line) {
                    return claude(object)
                }
                line.removeAll(keepingCapacity: true)
                continue
            }
            line.append(character)
        }
        if let object = jsonObject(from: line) {
            return claude(object)
        }
        return .signedOut
    }

    /// Exit 0 and output starting with `Logged in`. The detail is the rest of that line.
    static func codex(stdout: String, exitCode: Int32) -> SignInState {
        guard exitCode == 0 else { return .signedOut }
        let body = stdout.drop(while: \.isWhitespace)
        guard body.hasPrefix("Logged in") else { return .signedOut }
        var rest = body.dropFirst("Logged in".count)
        if let end = rest.firstIndex(where: \.isNewline) {
            rest = rest[..<end]
        }
        var detail = rest.trimmingCharacters(in: .whitespaces)
        if detail.hasPrefix("using ") {
            detail.removeFirst("using ".count)
        }
        return .signedIn(detail.isEmpty ? nil : detail)
    }

    /// The first line contains `logged in`. The detail is the text after `with `.
    static func grok(from stdout: String) -> SignInState {
        var line = ""
        for character in stdout {
            if character.isNewline { break }
            line.append(character)
        }
        let lowered = line.lowercased()
        if lowered.contains("not logged in") || lowered.contains("not signed in") {
            return .signedOut
        }
        guard lowered.contains("logged in") else { return .signedOut }
        return .signedIn(detail(after: "with ", in: line))
    }

    private static func claude(_ object: [String: Any]) -> SignInState {
        guard jsonBool(object["loggedIn"]) else { return .signedOut }
        return .signedIn(nonemptyString(object["authMethod"]))
    }

    private static func detail(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let detail = line[range.upperBound...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return detail.isEmpty ? nil : detail
    }
}

enum MuseAuth {
    /// `MUSE_AUTH_PATH` wins, then `$XDG_CONFIG_HOME/muse/auth.json`, then `~/.config/muse/auth.json`.
    static func file(home: URL, environment: [String: String]) -> String {
        if let override = nonempty(environment["MUSE_AUTH_PATH"]) {
            return AgentCommand.expandingTilde(override, home: home)
        }
        if let config = nonempty(environment["XDG_CONFIG_HOME"]) {
            let root = AgentCommand.expandingTilde(config, home: home)
            if root.hasSuffix("/") {
                return root + "muse/auth.json"
            }
            return root + "/muse/auth.json"
        }
        return AgentCommand.expandingTilde("~/.config/muse/auth.json", home: home)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum TerminalScript {
    static func shellCommand(executable: URL, arguments: [String]) -> String {
        let quoted = shellQuote(executable.path(percentEncoded: false))
        guard !arguments.isEmpty else { return quoted }
        return quoted + " " + arguments.joined(separator: " ")
    }

    /// A `.command` file that Terminal runs when opened. Scripting Terminal with Apple Events
    /// would need an entitlement the hardened runtime doesn't grant.
    static func commandFile(executable: URL, arguments: [String]) -> String {
        "#!/bin/bash\n" + shellCommand(executable: executable, arguments: arguments) + "\n"
    }

    static func open(_ contents: String) {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "\(Brand.slug)-sign-in-\(UUID().uuidString).command", directoryHint: .notDirectory)
        do {
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path(percentEncoded: false))
            NSWorkspace.shared.open(file)
        } catch {
            return
        }
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SignInCheck {
    /// A timeout or a failure to launch arrives as `nil` and stays `.unknown`.
    @concurrent
    static func evaluate(
        agent: AgentID,
        binary: URL?,
        home: URL,
        environment: [String: String],
        probe: @Sendable (URL, [String]) async -> SignInOutput?
    ) async -> SignInState {
        if agent == .muse {
            let path = MuseAuth.file(home: home, environment: environment)
            return FileManager.default.fileExists(atPath: path) ? .signedIn(nil) : .signedOut
        }
        guard let binary else { return .unknown }
        guard let output = await probe(binary, SignInCommand.checkArguments(for: agent)) else {
            return .unknown
        }
        switch agent {
        case .claude:
            return SignInStatus.claude(from: output.stdout)
        case .codex:
            return SignInStatus.codex(stdout: output.stdout.isEmpty ? output.stderr : output.stdout, exitCode: output.exitCode)
        case .grok:
            return SignInStatus.grok(from: output.stdout)
        case .muse:
            return .signedOut
        }
    }
}

/// Status checks need the process's real exit code. `AgentProcess` turns a non-zero exit into an error.
enum SignInCLI {
    static func run(
        executable: URL,
        arguments: [String],
        timeout: Duration = .seconds(10)
    ) async -> SignInOutput? {
        let running = RunningProcess()
        return await withTaskGroup(of: SignInOutput?.self) { group in
            group.addTask {
                await capture(executable: executable, arguments: arguments, running: running)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            running.stop()
            return first ?? nil
        }
    }

    @concurrent
    private static func capture(executable: URL, arguments: [String], running: RunningProcess) async -> SignInOutput? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = AgentCommand.environment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdout = PipeReader(stdoutPipe.fileHandleForReading)
        let stderr = PipeReader(stderrPipe.fileHandleForReading)
        let gate = OnceResume()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.attach(continuation)
                // A handler rather than `waitUntilExit()`, which once hung a test run on a worker thread.
                process.terminationHandler = { process in
                    // A helper the CLI started can inherit its pipes and hold them open, so the
                    // output is whatever arrived within a moment of exiting.
                    let deadline = DispatchTime.now() + 1
                    let out = stdout.finish(by: deadline)
                    let err = stderr.finish(by: deadline)
                    running.disarm()
                    let output: SignInOutput?
                    if process.terminationReason == .exit {
                        output = SignInOutput(
                            stdout: String(decoding: out, as: UTF8.self),
                            exitCode: process.terminationStatus,
                            stderr: String(decoding: err, as: UTF8.self)
                        )
                    } else {
                        output = nil
                    }
                    gate.resume(output)
                }
                do {
                    try process.run()
                } catch {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    gate.resume(nil)
                    return
                }
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                running.arm(process)
            }
        } onCancel: {
            // The timeout returns now; the process is stopped, and killed if it must be, behind it.
            gate.resume(nil)
            running.stop()
        }
    }
}

/// `Process` is not `Sendable`. Every access takes `state`, the process never escapes except to `terminate()`, and the lock is not held across a wait.
private final class RunningProcess: @unchecked Sendable {
    private struct State {
        var process: Process?
        var cancelled = false
    }

    private let state = Mutex<State>(State())

    func arm(_ process: Process) {
        let cancelled = state.withLock { state in
            state.process = process
            return state.cancelled
        }
        if cancelled {
            terminate(process)
        }
    }

    func stop() {
        let process = state.withLock { state in
            state.cancelled = true
            return state.process
        }
        if let process {
            terminate(process)
        }
    }

    func disarm() {
        state.withLock { $0.process = nil }
    }

    /// SIGTERM, then SIGKILL if the process is still running two seconds later, since the
    /// timeout can't return until the process has gone.
    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            state.withLock { state in
                guard let process = state.process, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

/// Collects a pipe's output as it arrives, without a thread blocked on it, so a reader can stop
/// while a process that inherited the pipe still holds it open.
private final class PipeReader: Sendable {
    private let handle: FileHandle
    private let data = Mutex<Data>(Data())
    /// Starts at zero and is signalled at end of file, so it's safe to release unsignalled.
    private let closed = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.closed.signal()
            } else {
                self?.data.withLock { $0.append(chunk) }
            }
        }
    }

    /// What arrived by end of file or `deadline`, whichever is first; after that it stops reading.
    func finish(by deadline: DispatchTime) -> Data {
        if closed.wait(timeout: deadline) == .timedOut {
            handle.readabilityHandler = nil
        }
        return data.withLock { $0 }
    }
}

/// Resumes a continuation once, whichever comes first: the result, or the timeout. The timeout
/// can come before the continuation exists, and is then delivered when it does.
private final class OnceResume: Sendable {
    private struct State {
        var continuation: CheckedContinuation<SignInOutput?, Never>?
        var result: SignInOutput??
    }

    private let state = Mutex(State())

    func attach(_ continuation: CheckedContinuation<SignInOutput?, Never>) {
        let early = state.withLock { state -> SignInOutput?? in
            if let result = state.result { return .some(result) }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ value: SignInOutput?) {
        let continuation = state.withLock { state -> CheckedContinuation<SignInOutput?, Never>? in
            guard state.result == nil else { return nil }
            state.result = .some(value)
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }
}
