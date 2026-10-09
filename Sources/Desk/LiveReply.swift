import Observation

/// Text and thinking of the reply streaming now that haven't reached `threads` yet. Deltas show
/// here within 50 ms and reach the thread within half a second. Only that reply's row reads this,
/// so a chunk redraws one row instead of every view that reads the threads.
@MainActor
@Observable
final class LiveReply {
    static let showDelay: Duration = .milliseconds(50)
    static let saveDelay: Duration = .milliseconds(500)

    let id: Message.ID
    private(set) var text = ""
    private(set) var thinking = ""
    @ObservationIgnored private var heldText = ""
    @ObservationIgnored private var heldThinking = ""
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let save: ([AgentEvent]) -> Void

    init(id: Message.ID, save: @escaping ([AgentEvent]) -> Void) {
        self.id = id
        self.save = save
    }

    /// Keeps a text or thinking delta; any other event is not held.
    func hold(_ event: AgentEvent) -> Bool {
        switch event {
        case .text(let chunk): heldText += chunk
        case .thinking(let chunk): heldThinking += chunk
        default: return false
        }
        if showTask == nil {
            showTask = after(Self.showDelay) { $0.show() }
        }
        return true
    }

    /// Hands everything held or shown to the thread now.
    func flush() {
        showTask?.cancel()
        saveTask?.cancel()
        showTask = nil
        saveTask = nil
        var events: [AgentEvent] = []
        if !(thinking + heldThinking).isEmpty { events.append(.thinking(thinking + heldThinking)) }
        if !(text + heldText).isEmpty { events.append(.text(text + heldText)) }
        heldText = ""
        heldThinking = ""
        if !text.isEmpty { text = "" }
        if !thinking.isEmpty { thinking = "" }
        if !events.isEmpty { save(events) }
    }

    /// The saved message with what has streamed in since.
    func shown(_ message: Message) -> Message {
        guard !text.isEmpty || !thinking.isEmpty else { return message }
        var shown = message
        shown.body += text
        shown.thinking += thinking
        return shown
    }

    private func show() {
        showTask = nil
        if !heldText.isEmpty { text += heldText }
        if !heldThinking.isEmpty { thinking += heldThinking }
        heldText = ""
        heldThinking = ""
        if saveTask == nil {
            saveTask = after(Self.saveDelay) { $0.flush() }
        }
    }

    private func after(_ delay: Duration, _ run: @escaping (LiveReply) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            if let self { run(self) }
        }
    }
}
