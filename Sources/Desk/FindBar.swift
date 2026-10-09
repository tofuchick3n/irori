import SwiftUI

/// Finds text in the open thread. Return goes to the next match, Shift-Return to the previous one.
struct FindBar: View {
    @Bindable var model: DeskModel
    let count: Int
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in Thread", text: $model.findQuery)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    model.moveFind(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onExitCommand(perform: model.endFind)
            Text(status)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            ControlGroup {
                Button("Previous", systemImage: "chevron.up") { model.moveFind(-1) }
                    .help("Previous match (⇧⌘G)")
                Button("Next", systemImage: "chevron.down") { model.moveFind(1) }
                    .help("Next match (⌘G)")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            .disabled(count == 0)
            Button("Done", action: model.endFind)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .onAppear { isFocused = true }
        .onChange(of: model.findFocusRequest) { isFocused = true }
    }

    private var status: String {
        guard !model.findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let index = model.currentFindIndex(among: count) else { return "Not found" }
        return "\(index + 1) of \(count)"
    }
}
