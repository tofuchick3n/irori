import SwiftUI

/// The README's table of what each agent can do, with the column for the current setting highlighted.
struct AgentCapabilitiesGrid: View {
    var writesOn: Bool

    private static let rows: [(agent: AgentID, on: String, off: String)] = [
        (.claude, "Edits files in the thread's folder; runs read-only commands and the shell commands you allow (default: takibi)", "Asks before each edit"),
        (.codex, "Its sandbox allows writes to the thread's folder and network access", "Read-only sandbox, no network"),
        (.grok, "Its sandbox allows writes to the thread's folder", "Read-only sandbox"),
        (.muse, "Writes to the thread's folder", "No writes and no shell (so no takibi)"),
    ]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Agent")
                Text("With file writes on")
                Text("With file writes off")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(Self.rows, id: \.agent) { row in
                GridRow {
                    Text(row.agent.displayName)
                        .fontWeight(.semibold)
                    cell(row.on, current: writesOn)
                    cell(row.off, current: !writesOn)
                }
            }
        }
    }

    private func cell(_ text: String, current: Bool) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
