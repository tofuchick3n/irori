import Darwin
import Foundation

/// Stdin of one agent process. Writes are recorded even before the handle is attached so a session can be tested without spawning.
final class AgentStdin: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var closed = false
    private var lines: [String] = []

    func attach(_ handle: FileHandle) {
        // A late approval answer can reach a child that already exited; that must fail the write, not kill Desk.
        signal(SIGPIPE, SIG_IGN)
        lock.lock()
        if closed {
            lock.unlock()
            try? handle.close()
            return
        }
        self.handle = handle
        lock.unlock()
    }

    func write(_ line: String) {
        let text = line.hasSuffix("\n") ? String(line.dropLast()) : line
        let data = Data((text + "\n").utf8)
        lock.lock()
        lines.append(text)
        let handle = closed ? nil : self.handle
        lock.unlock()
        guard let handle else { return }
        try? handle.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        try? handle?.close()
    }

    func writtenLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
