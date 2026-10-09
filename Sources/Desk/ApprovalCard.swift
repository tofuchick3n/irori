import SwiftUI

/// "Claude wants to: Run touch probe.txt" with the answers. A denial stays as one line; an allow joins the reply's work log.
struct ApprovalCard: View {
    let record: ApprovalRecord
    let isWaiting: Bool
    let decide: (ApprovalDecision) -> Void

    var body: some View {
        if isWaiting {
            waiting
        } else {
            HStack(spacing: 8) {
                mark
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var mark: some View {
        Image(nsImage: AgentLogo.image(for: record.agent, side: 16))
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                mark
                Text("\(record.agent.displayName) is asking:")
                    .foregroundStyle(.secondary)
                Text(record.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
            }
            if let detail = record.detail, detail != record.title {
                DisclosureGroup("Details") {
                    Text(detail)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .font(.callout)
            }
            FlowLayout(spacing: 8) {
                Button("Allow Once") { decide(.allowOnce) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Allow in This Thread") { decide(.allowInThread) }
                    .help("Allow \(ApprovalRule.friendlyName(record.rule)) for the rest of this thread.")
                Button("Always Allow") { decide(.allowAlways) }
                    .help("Allow \(ApprovalRule.friendlyName(record.rule)) everywhere. You can remove it in Settings → Permissions.")
                Button("Allow Everything in This Thread") { decide(.allowEverything) }
                    .help("Allow every later request in this thread, from every agent. Reset Permissions for This Thread in the sidebar turns it off.")
                Button("Deny") { decide(.deny) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var summary: String { record.summary }
}
