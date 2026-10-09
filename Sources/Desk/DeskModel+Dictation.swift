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
        guard dictation.isActive else { return send() }
        // Already finishing for an earlier Return, which sends.
        guard dictation.state != .finishing else { return }
        Task {
            await dictation.finish()
            send()
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
