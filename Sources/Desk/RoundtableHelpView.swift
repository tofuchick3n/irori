import SwiftUI

struct RoundtableHelpView: View {
    static let windowID = "roundtable-help"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How Roundtables Work")
                    .font(.title.bold())
                section(
                    "Taking turns",
                    "Agents reply one at a time. Type @ to choose who answers: @claude, @codex, @grok, or @muse. Without a mention, the thread keeps replying to whoever you last mentioned. @all means one reply per agent, each a separate model call."
                )
                section(
                    "Reading each other",
                    "Every agent sees the whole thread, including the other agents' replies, so they can build on or argue with each other."
                )
                section(
                    "Folders and files",
                    "Each thread has its own folder. Anything an agent makes lands there, and the Files drawer lists it so you can preview it."
                )
                section(
                    "What agents may do",
                    "With file writes on, agents can create and edit files in the thread's folder and nowhere else. Commands you've allowed never ask; the list is in Settings under Permissions."
                )
                section(
                    "Approvals",
                    "Claude and Codex ask in the thread before anything beyond reading and read-only commands. Allow it once, for this thread, always, or everything in the thread, or say no."
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 460)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
