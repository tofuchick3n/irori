import Foundation

/// Answered allows are steps on the following reply, not their own transcript rows.
/// Waiting cards and denials stay rows. An allow with no reply after it stays a row too,
/// so a saved thread never drops one.
enum TranscriptRows {
    struct Row: Identifiable, Equatable {
        var message: Message
        /// Allows from older saves, which predate steps stored on the reply.
        var approvalSteps: [WorkStep] = []

        var id: Message.ID { message.id }
    }

    static func rows(in messages: [Message]) -> [Row] {
        var rows: [Row] = []
        var pending: [Message] = []
        for message in messages {
            if message.approval?.decision?.allows == true {
                pending.append(message)
                continue
            }
            if case .agent = message.author {
                let have = Set(message.steps.map(\.id))
                let extra = pending.compactMap { card -> WorkStep? in
                    guard let approval = card.approval else { return nil }
                    let step = WorkStep.approval(approval, id: card.id, at: card.createdAt)
                    return have.contains(step.id) ? nil : step
                }
                rows.append(Row(message: message, approvalSteps: extra))
                pending.removeAll()
                continue
            }
            rows.append(Row(message: message))
        }
        for message in pending {
            rows.append(Row(message: message))
        }
        return rows
    }
}
