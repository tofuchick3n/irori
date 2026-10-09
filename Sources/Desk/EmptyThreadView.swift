import SwiftUI

struct EmptyThreadView: View {
    var model: DeskModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(hint)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(ExamplePrompts.make(active: model.activeAgents), id: \.self) { prompt in
                    Button(prompt.trimmingCharacters(in: .whitespaces)) {
                        model.draft = prompt
                        model.composerFocusRequest += 1
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hint: String {
        guard let agent = model.effectiveDefaultAgent else {
            return "No agents are available yet. Install one, or turn one on in Settings."
        }
        return "Type @ to choose who answers. Without a mention, \(agent.displayName) answers."
    }
}
