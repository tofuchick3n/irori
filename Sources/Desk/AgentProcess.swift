import Darwin
import Foundation

/// Opened after the agent process has exited. Cancelling the stream resumes the
/// consumer before `waitForExit` returns, so Desk waits here before trashing a workspace.
/// Mutable state is private, every access takes `lock`, and the lock is not held across `await`.
final class AgentExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func claim() {
        lock.lock()
        claimed = true
        lock.unlock()
    }

    func open() {
        lock.lock()
        opened = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened || !claimed {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

enum AgentRunGate {
    @TaskLocal static var current: AgentExitGate?
}

struct AgentProcess: Sendable {
    var label: String
    /// Overrides binary resolution. Tests pass a stand-in executable; the app leaves this nil.
    var executable: URL?
    var candidates: [String]
    var arguments: [String]
    var environment: [String: String]
    var workspace: URL
    var notFound: String
    /// Stderr substrings that mean the stored session cannot be resumed.
    var missingSessionMarkers: [String] = []
    /// When set, stdin stays open and the parser writes the protocol on it.
    var stdin: AgentStdin?
    /// Exit 0 ends the run even when the parser never saw a final result. Model discovery uses this.
    var succeedsOnCleanExit = false

    func run<Parser: AgentLineParser>(
        _ makeParser: @escaping @Sendable () -> Parser
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let label = label
        let executable = executable
        let candidates = candidates
        let arguments = arguments
        let environment = environment
        let workspace = workspace
        let notFound = notFound
        let missingSessionMarkers = missingSessionMarkers
        let stdin = stdin
        let succeedsOnCleanExit = succeedsOnCleanExit
        return AsyncThrowingStream { continuation in
            let gate = AgentRunGate.current
            gate?.claim()
            let box = AgentProcessBox()
            let task = Task {
                defer { gate?.open() }
                do {
                    try await runAgent(
                        label: label,
                        executable: executable,
                        candidates: candidates,
                        arguments: arguments,
                        environment: environment,
                        workspace: workspace,
                        notFound: notFound,
                        missingSessionMarkers: missingSessionMarkers,
                        stdin: stdin,
                        succeedsOnCleanExit: succeedsOnCleanExit,
                        box: box,
                        makeParser: makeParser
                    ) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    box.stop()
                    continuation.finish()
                } catch {
                    box.stop()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                box.stop()
                task.cancel()
            }
        }
    }
}

private func runAgent<Parser: AgentLineParser>(
    label: String,
    executable: URL?,
    candidates: [String],
    arguments: [String],
    environment: [String: String],
    workspace: URL,
    notFound: String,
    missingSessionMarkers: [String],
    stdin: AgentStdin?,
    succeedsOnCleanExit: Bool,
    box: AgentProcessBox,
    makeParser: @Sendable () -> Parser,
    yield: @escaping @Sendable (AgentEvent) -> Void
) async throws {
    try Task.checkCancellation()
    let binary: URL
    if let executable {
        binary = executable
    } else if let resolved = AgentCommand.resolve(candidates: candidates) {
        binary = resolved
    } else {
        throw AgentRunError(message: notFound, notInstalled: true)
    }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let spawned = try spawnAgent(
        label: label,
        binary: binary,
        arguments: arguments,
        environment: environment,
        workspace: workspace
    )
    box.attach(pgid: spawned.pgid)
    AgentProcessGroups.shared.insert(spawned.pgid)
    let stdout = spawned.stdout
    let stderr = spawned.stderr
    if let stdin {
        stdin.attach(spawned.stdin)
    } else {
        do {
            try spawned.stdin.close()
        } catch {
            box.stop()
            throw error
        }
    }
    defer { stdin?.close() }
    box.stopIfRequested()

    async let stderrTail = collectTail(stderr, maxBytes: stderrMarkerBytes)
    var parser = makeParser()
    parser.sessionStarted()
    var streamError: Error?
    var parserError: Error?
    var exitGrace: DispatchWorkItem?
    defer { exitGrace?.cancel() }
    func endSoon() {
        guard exitGrace == nil else { return }
        let grace = DispatchWorkItem { box.stop() }
        exitGrace = grace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: grace)
    }
    do {
        for try await line in stdout.bytes.lines {
            try Task.checkCancellation()
            let events: [AgentEvent]
            do {
                events = try parser.events(from: line)
            } catch {
                // Hold the parser error until exit and stderr are known. A missing
                // session (Claude's error result plus a stderr marker) must win.
                parserError = error
                break
            }
            for event in events {
                yield(event)
            }
            // The turn is over once the final result arrives. A CLI that then
            // hangs while shutting down its own helpers must not freeze Desk.
            if parser.finishedCleanly {
                stdin?.close()
                endSoon()
            }
        }
    } catch {
        streamError = error
        box.stop()
    }
    if parserError != nil {
        endSoon()
    }

    let status = await waitForExit(spawned.pid)
    AgentProcessGroups.shared.remove(spawned.pgid)
    let stderrData = try await stderrTail
    if streamError is CancellationError || parserError is CancellationError {
        throw CancellationError()
    }
    if Task.isCancelled {
        return
    }
    let messageTail = Data(stderrData.suffix(stderrMessageBytes))
    let waitFailed = status == nil
    let code = status.flatMap(exitCode(of:))
    if parserError != nil || waitFailed || code != 0,
       let message = missingSessionMessage(stderr: stderrData, messageTail: messageTail, markers: missingSessionMarkers, label: label) {
        throw AgentRunError(message: message, missingSession: true)
    }
    if let parserError {
        throw parserError
    }
    if let streamError {
        throw streamError
    }
    if parser.finishedCleanly || (succeedsOnCleanExit && code == 0) {
        return
    }
    guard let status else {
        let text = decodeTail(messageTail).trimmingCharacters(in: .whitespacesAndNewlines)
        throw AgentRunError(message: text.isEmpty ? "\(label) exited." : text)
    }
    if exitCode(of: status) == 0 {
        throw AgentRunError(message: "\(label) ended without a final reply.")
    }
    throw AgentRunError(message: failureMessage(label: label, stderr: messageTail, status: status))
}

private func missingSessionMessage(stderr: Data, messageTail: Data, markers: [String], label: String) -> String? {
    let search = decodeTail(stderr)
    guard markers.contains(where: { !$0.isEmpty && search.contains($0) }) else { return nil }
    let trimmed = decodeTail(messageTail).trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        return trimmed
    }
    return "\(label)'s session wasn't found."
}

private func failureMessage(label: String, stderr: Data, status: Int32) -> String {
    let text = decodeTail(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
        return text
    }
    if let code = exitCode(of: status) {
        return "\(label) exited with status \(code)."
    }
    if let signal = termSignal(of: status) {
        return "\(label) was killed by signal \(signal)."
    }
    return "\(label) exited."
}

private func exitCode(of status: Int32) -> Int32? {
    status & 0x7f == 0 ? (status >> 8) & 0xff : nil
}

private func termSignal(of status: Int32) -> Int32? {
    let signal = status & 0x7f
    return signal == 0 || signal == 0x7f ? nil : signal
}

private let stderrMessageBytes = 2048
private let stderrMarkerBytes = 65_536

private func collectTail(_ handle: FileHandle, maxBytes: Int = stderrMessageBytes) async throws -> Data {
    // A blocking stderr AsyncBytes read can hold Foundation's shared I/O queue and stall stdout.
    let data = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            do {
                var data = Data()
                while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                    data.append(chunk)
                    if data.count > maxBytes * 2 {
                        data.removeFirst(data.count - maxBytes)
                    }
                }
                if data.count > maxBytes {
                    data.removeFirst(data.count - maxBytes)
                }
                continuation.resume(returning: data)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    try Task.checkCancellation()
    return data
}

private func decodeTail(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) {
        return text
    }
    var start = data.startIndex
    while start < data.endIndex {
        start = data.index(after: start)
        if let text = String(data: data[start...], encoding: .utf8) {
            return text
        }
    }
    return ""
}

private struct SpawnedAgent {
    var pid: pid_t
    var pgid: pid_t
    var stdin: FileHandle
    var stdout: FileHandle
    var stderr: FileHandle
}

private func spawnAgent(
    label: String,
    binary: URL,
    arguments: [String],
    environment: [String: String],
    workspace: URL
) throws -> SpawnedAgent {
    let stdin = try PipeEnds.open()
    let stdout = try PipeEnds.open()
    let stderr = try PipeEnds.open()
    var spawned = false
    defer {
        if !spawned {
            stdin.closeBoth()
            stdout.closeBoth()
            stderr.closeBoth()
        }
    }

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw AgentRunError(message: posixMessage(errno))
    }
    defer { posix_spawn_file_actions_destroy(&actions) }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
        throw AgentRunError(message: posixMessage(errno))
    }
    defer { posix_spawnattr_destroy(&attributes) }

    // Start the child the way Foundation.Process does: an empty signal mask,
    // default dispositions, and no inherited descriptors besides stdin, stdout,
    // and stderr. Pipes are marked close-on-exec after pipe(), so a spawn on
    // another thread in between would otherwise leak another agent's pipes.
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
    guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
          posix_spawnattr_setsigdefault(&attributes, &allSignals) == 0 else {
        throw AgentRunError(message: posixMessage(errno))
    }

    let directory = workspace.path(percentEncoded: false)
    guard posix_spawn_file_actions_addchdir(&actions, directory) == 0 else {
        throw AgentRunError(message: posixMessage(errno))
    }
    try addStandardIO(actions: &actions, stdin: stdin, stdout: stdout, stderr: stderr)

    var pid: pid_t = 0
    let argv = [binary.path(percentEncoded: false)] + arguments
    let env = environment.map { "\($0.key)=\($0.value)" }.sorted()
    let spawnedResult = try withCStrings(label: label, argv) { argvPointer in
        try withCStrings(label: label, env) { envPointer in
            posix_spawn(&pid, binary.path(percentEncoded: false), &actions, &attributes, argvPointer, envPointer)
        }
    }
    guard spawnedResult == 0 else {
        throw AgentRunError(message: posixMessage(spawnedResult))
    }
    spawned = true

    Darwin.close(stdin.read)
    Darwin.close(stdout.write)
    Darwin.close(stderr.write)

    // Spawned with setpgroup(0), the group id is the pid. A child that already exited has no
    // group to look up (ESRCH), which is not the failure this check is for.
    var pgid = getpgid(pid)
    if pgid == -1, errno == ESRCH {
        pgid = pid
    }
    let ownGroup = getpgrp()
    guard pgid > 1, pgid != ownGroup else {
        Darwin.kill(pid, SIGKILL)
        throw AgentRunError(message: "\(label) did not start in its own process group.")
    }

    return SpawnedAgent(
        pid: pid,
        pgid: pgid,
        stdin: FileHandle(fileDescriptor: stdin.write, closeOnDealloc: true),
        stdout: FileHandle(fileDescriptor: stdout.read, closeOnDealloc: true),
        stderr: FileHandle(fileDescriptor: stderr.read, closeOnDealloc: true)
    )
}

private func addStandardIO(
    actions: inout posix_spawn_file_actions_t?,
    stdin: PipeEnds,
    stdout: PipeEnds,
    stderr: PipeEnds
) throws {
    guard posix_spawn_file_actions_adddup2(&actions, stdin.read, STDIN_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&actions, stdout.write, STDOUT_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&actions, stderr.write, STDERR_FILENO) == 0 else {
        throw AgentRunError(message: posixMessage(errno))
    }
    for fd in [stdin.read, stdin.write, stdout.read, stdout.write, stderr.read, stderr.write] where fd > STDERR_FILENO {
        guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else {
            throw AgentRunError(message: posixMessage(errno))
        }
    }
}

private func withCStrings<T>(
    label: String,
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T
) throws -> T {
    let allocated = strings.map { strdup($0) }
    defer { allocated.forEach { free($0) } }
    guard allocated.allSatisfy({ $0 != nil }) else {
        throw AgentRunError(message: "\(label) could not be launched.")
    }
    var pointers: [UnsafeMutablePointer<CChar>?] = allocated
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else {
            throw AgentRunError(message: "\(label) could not be launched.")
        }
        return try body(base)
    }
}

/// Every agent process group still running, so quitting Desk can end them rather than orphan them.
final class AgentProcessGroups: @unchecked Sendable {
    static let shared = AgentProcessGroups()
    private let lock = NSLock()
    private var groups: Set<pid_t> = []

    func insert(_ pgid: pid_t) {
        lock.lock()
        groups.insert(pgid)
        lock.unlock()
    }

    func remove(_ pgid: pid_t) {
        lock.lock()
        groups.remove(pgid)
        lock.unlock()
    }

    var running: Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return groups
    }

    /// Sends SIGTERM to every group, waits up to `grace` for them to exit, then SIGKILLs the rest.
    func terminateAll(grace: TimeInterval = 1) {
        let targets = running.filter { $0 > 1 && $0 != getpgrp() }
        guard !targets.isEmpty else { return }
        for pgid in targets {
            Darwin.kill(-pgid, SIGTERM)
        }
        let deadline = Date.now.addingTimeInterval(grace)
        while Date.now < deadline, targets.contains(where: { Darwin.kill(-$0, 0) == 0 }) {
            usleep(50_000)
        }
        for pgid in targets where Darwin.kill(-pgid, 0) == 0 {
            Darwin.kill(-pgid, SIGKILL)
        }
    }
}

func waitForExit(_ pid: pid_t) async -> Int32? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while true {
                let result = waitpid(pid, &status, 0)
                if result == pid {
                    continuation.resume(returning: status)
                    return
                }
                if result == -1, errno == EINTR {
                    continue
                }
                continuation.resume(returning: nil)
                return
            }
        }
    }
}

private func posixMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
}

private struct PipeEnds {
    var read: Int32
    var write: Int32

    static func open() throws -> PipeEnds {
        var fds = [Int32](repeating: 0, count: 2)
        guard pipe(&fds) == 0 else {
            throw AgentRunError(message: posixMessage(errno))
        }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        return PipeEnds(read: fds[0], write: fds[1])
    }

    func closeBoth() {
        Darwin.close(read)
        Darwin.close(write)
    }
}

private final class AgentProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pgid: pid_t?
    private var stopped = false
    private var killScheduled = false

    func attach(pgid: pid_t) {
        lock.lock()
        self.pgid = pgid
        let shouldStop = stopped
        lock.unlock()
        if shouldStop {
            terminate(pgid)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let pgid = self.pgid
        lock.unlock()
        guard let pgid else { return }
        terminate(pgid)
    }

    func stopIfRequested() {
        lock.lock()
        let shouldStop = stopped
        let pgid = self.pgid
        lock.unlock()
        guard shouldStop, let pgid else { return }
        terminate(pgid)
    }

    private func terminate(_ pgid: pid_t) {
        guard pgid > 1, pgid != getpgrp() else { return }
        Darwin.kill(-pgid, SIGTERM)
        lock.lock()
        let schedule = !killScheduled
        killScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            guard Darwin.kill(-pgid, 0) == 0 else { return }
            Darwin.kill(-pgid, SIGKILL)
        }
    }
}
