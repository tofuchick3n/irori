import SwiftUI

/// A message waiting for the turn in progress, dimmed until it is sent.
struct QueuedMessageRow: View {
    let queued: QueuedMessage
    let userName: String
    let userPhoto: NSImage?
    let sendNow: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(kind: .user(userPhoto))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(userName)
                        .fontWeight(.semibold)
                    Label("Queued", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Send Now", systemImage: "arrow.up.circle", action: sendNow)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Stop the reply in progress and send this now (⌘↩)")
                    Button("Cancel", systemImage: "xmark.circle", action: cancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Cancel the queued message")
                }
                .font(.system(size: MarkdownRenderer.bodySize))
                if !queued.text.isEmpty {
                    Text(queued.text)
                        .font(.system(size: MarkdownRenderer.bodySize))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !queued.attachments.isEmpty {
                    Label(queued.attachments.map(\.lastPathComponent).joined(separator: ", "), systemImage: "paperclip")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
