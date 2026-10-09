import AppKit

extension DeskModel {
    func toggleDictation() {
        if dictation.isActive {
            Task { await dictation.finish() }
            return
        }
        guard let threadID = selection else { return }
        composerFocusRequest += 1
        let read = { [weak self] in self?.drafts[threadID] ?? "" }
        let write = { [weak self] (text: String) -> Void in self?.drafts[threadID] = text }
        Task {
            await dictation.start(threadID: threadID, read: read, write: write)
        }
    }

    /// Return while dictating sends once the last words are in.
    func finishDictationAndSend() {
        finishDictation(then: send)
    }

    func finishDictationAndSendNow() {
        finishDictation(then: sendNow, now: true)
    }

    /// One send per finish: a second Return waits for the first, and ⌘↩ meanwhile upgrades it to send now.
    private func finishDictation(then action: @escaping () -> Void, now: Bool = false) {
        guard dictation.isActive || dictationSend != nil else { return action() }
        if dictationSend != nil {
            dictationSendsNow = dictationSendsNow || now
            return
        }
        dictationSendsNow = now
        let threadID = selection
        dictationSend = Task {
            await dictation.finish()
            dictationSend = nil
            // Switched threads meanwhile: the words stay in their own thread's draft, unsent.
            guard selection == threadID else { return }
            if dictationSendsNow { sendNow() } else { send() }
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
