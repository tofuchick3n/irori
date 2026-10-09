import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    var model: DeskModel

    var body: some View {
        ComposerField(
            text: Binding(get: { model.draft }, set: { model.draft = $0 }),
            threadID: model.selection,
            isRunning: model.isRunning,
            activeAgents: model.activeAgents,
            placeholder: placeholder,
            focusRequest: model.composerFocusRequest,
            attachments: model.attachments,
            removeAttachment: model.removeAttachment,
            addAttachments: model.addAttachments,
            onSubmit: model.finishDictationAndSend,
            onEscape: model.dismissForEscape
        ) {
            HStack(spacing: 8) {
                Button("Attach", systemImage: "paperclip", action: chooseFiles)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Attach files")
                if !model.nextRecipients.isEmpty {
                    RecipientsMenu(model: model, agents: model.nextRecipients)
                }
                if model.repliersCarryOver, let agent = model.effectiveDefaultAgent {
                    Button("Back to \(agent.displayName)", systemImage: "xmark.circle.fill", action: model.forgetEarlierMentions)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Only \(agent.displayName) replies next")
                }
                Spacer(minLength: 8)
                if let problem = model.dictation.problem, !model.dictation.isActive {
                    Text(problem)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if model.dictation.needsMicrophoneAccess {
                        Button("Open Settings", action: model.openMicrophoneSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                if model.isRunning, !model.selectedThreadIsRunning, let title = model.runningThreadTitle {
                    Text("Waiting for “\(title)” to finish")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Stop", action: model.stop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if model.dictation.isAvailable {
                    DictationButton(model: model)
                }
                sendButton
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 24))
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var sendButton: some View {
        if model.selectedThreadIsRunning {
            Button("Stop", systemImage: "stop.circle.fill", action: model.stop)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color(nsColor: .textBackgroundColor), Color.primary)
                .help("Stop the reply, and skip any agents still waiting")
        } else {
            Button("Send", systemImage: "arrow.up.circle.fill", action: model.finishDictationAndSend)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                .disabled(!canSend)
                .help("Send")
        }
    }

    private var canSend: Bool {
        !model.isRunning && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        model.addAttachments(panel.urls)
    }

    private var placeholder: String {
        let names = model.nextRecipients.map(\.displayName)
        switch names.count {
        case 0: return "Message"
        case 1: return "Message \(names[0])"
        case 2: return "Message \(names[0]) and \(names[1])"
        default: return "Message \(names.dropLast().joined(separator: ", ")), and \(names[names.count - 1])"
        }
    }
}

/// Starts and stops voice input; the waveform moves while it listens.
private struct DictationButton: View {
    var model: DeskModel

    var body: some View {
        let listening = model.dictation.isActive
        Button(listening ? "Stop Voice Input" : "Voice Input", systemImage: listening ? "waveform" : "mic", action: model.toggleDictation)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 17))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .foregroundStyle(listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .symbolEffect(.variableColor.iterative, isActive: listening)
            .contentTransition(.symbolEffect(.replace))
            .help(listening ? "Stop voice input (⇧⌘D)" : "Voice input (⇧⌘D)")
    }
}

/// Who will reply to the draft, with each one's model and effort. Changes here apply everywhere.
private struct RecipientsMenu: View {
    var model: DeskModel
    let agents: [AgentID]

    var body: some View {
        Menu {
            ForEach(agents, id: \.self) { agent in
                Section(agent.displayName) {
                    AgentSettingsPickers(model: model, agent: agent)
                }
            }
            Divider()
            DefaultAgentPicker(model: model, inComposer: true)
            Text("Type @ in your message to choose who replies.")
        } label: {
            HStack(spacing: 5) {
                ForEach(agents, id: \.self) { agent in
                    Image(nsImage: AgentLogo.image(for: agent, side: 14))
                }
                Text(summary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Change each agent's model and effort")
    }

    private var summary: String {
        guard agents.count == 1, let agent = agents.first else {
            return agents.map(\.displayName).joined(separator: ", ") + " in turn"
        }
        let settings = AgentSettingsPickers(model: model, agent: agent)
        return ([agent.displayName, settings.modelLabel] + [settings.effortLabel].compactMap { $0 }).joined(separator: " · ")
    }
}

/// Who answers when nobody has been mentioned, shared by the composer menu and Settings.
/// In the composer it shows who replies next, and choosing someone also overrides earlier mentions in the thread.
struct DefaultAgentPicker: View {
    var model: DeskModel
    var inComposer = false

    var body: some View {
        Picker("Answers when nobody is mentioned", selection: selection) {
            ForEach(model.activeAgents, id: \.self) { agent in
                Label {
                    Text(agent.displayName)
                } icon: {
                    Image(nsImage: AgentLogo.menuImage(for: agent, side: 16))
                }
                .tag(agent)
            }
        }
        // A mention in the draft decides who replies, so picking someone here wouldn't stick.
        .disabled(inComposer && !Turn.mentionedAgents(in: model.draft).isEmpty)
    }

    private var selection: Binding<AgentID> {
        Binding(
            get: {
                if inComposer, model.nextRecipients.count == 1, let next = model.nextRecipients.first {
                    return next
                }
                return model.effectiveDefaultAgent ?? model.defaultAgent
            },
            set: { inComposer ? model.chooseNextReplier($0) : model.setDefaultAgent($0) }
        )
    }
}

/// Model and effort pickers for one agent, shared by the composer menu and Settings.
struct AgentSettingsPickers: View {
    var model: DeskModel
    let agent: AgentID

    var body: some View {
        Picker("Model", selection: modelSelection) {
            ForEach(model.catalog.options[agent] ?? []) { option in
                Text(option.label).tag(Optional(option.id))
            }
        }
        if !efforts.isEmpty {
            Picker("Effort", selection: effortSelection) {
                ForEach(efforts) { option in
                    Text(option.label).tag(Optional(option.id))
                }
            }
        }
    }

    var modelLabel: String {
        guard let id = model.modelForRun(for: agent) else { return "the CLI's own" }
        return model.catalog.label(for: id, agent: agent)
    }

    /// The effort that runs.
    var effortLabel: String? {
        guard let id = model.effortForRun(for: agent) else { return nil }
        return efforts.first { $0.id == id }?.label ?? id
    }

    /// Lowest to highest, whatever order the CLI lists them in.
    private var efforts: [AgentEffortOption] {
        model.catalog.efforts(for: agent, model: model.modelForRun(for: agent)).sorted {
            ModelLists.effortRank($0.id) < ModelLists.effortRank($1.id)
        }
    }

    private var modelSelection: Binding<String?> {
        Binding(get: { model.modelForRun(for: agent) }, set: { model.setSelectedModel($0, for: agent) })
    }

    private var effortSelection: Binding<String?> {
        Binding(get: { model.effortForRun(for: agent) }, set: { model.setSelectedEffort($0, for: agent) })
    }
}

private struct ComposerField<Accessory: View>: View {
    @Binding var text: String
    var threadID: Thread.ID?
    var isRunning: Bool
    var activeAgents: [AgentID]
    var placeholder: String
    var focusRequest: Int
    var attachments: [URL]
    var removeAttachment: (URL) -> Void
    var addAttachments: ([URL]) -> Void
    var onSubmit: () -> Void
    /// Escape with no mention list showing; returns whether it did anything.
    var onEscape: () -> Bool = { false }
    @ViewBuilder var accessory: Accessory

    @State private var selection: TextSelection?
    /// Caret indices belong to one string. Ignore the selection when the thread or length no longer matches it.
    @State private var selectionThreadID: Thread.ID?
    @State private var selectionTextCount = 0
    @State private var highlight = 0
    @State private var dismissed: Mention.Query?
    @FocusState private var editorFocused: Bool

    private static var maxLines: Int { 8 }
    private static var verticalInset: CGFloat { 9 }

    var body: some View {
        // Floats above the field, so opening it doesn't push the transcript up.
        field
            .overlay(alignment: .topLeading) {
                // A line along the field's top edge, with the list standing on it.
                Color.clear
                    .frame(height: 0)
                    .overlay(alignment: .bottomLeading) {
                        if !choices.isEmpty {
                            mentionList
                                .padding(.bottom, 8)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                        }
                    }
            }
            .animation(.snappy(duration: 0.15), value: choices.isEmpty)
        .onAppear {
            if selection == nil {
                placeCaretAtEnd()
            }
        }
        .onChange(of: threadID) { _, _ in
            placeCaretAtEnd()
            highlight = 0
            dismissed = nil
        }
        .onChange(of: text) { _, new in
            if new.isEmpty {
                placeCaretAtEnd()
            } else if threadID == selectionThreadID {
                selectionTextCount = new.count
            }
        }
        .onChange(of: selection) { _, _ in
            guard threadID == selectionThreadID || selectionTextCount == 0 else { return }
            selectionTextCount = text.count
            selectionThreadID = threadID
        }
        .onChange(of: query) { _, _ in
            highlight = 0
        }
        .onChange(of: focusRequest) { _, _ in
            placeCaretAtEnd()
            editorFocused = true
        }
    }

    /// One card: the text on top, the recipients and Send/Stop in a bar along the bottom.
    private var field: some View {
        VStack(spacing: 0) {
            if !attachments.isEmpty {
                AttachmentChips(urls: attachments, remove: removeAttachment)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }
            editor
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .onTapGesture {
                    editorFocused = true
                }
            accessory
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if editorFocused {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addAttachments(urls)
            return !urls.isEmpty
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            nonisolated(unsafe) let providers = providers
            Task { @MainActor in
                addAttachments(await PastedFiles.urls(from: providers))
            }
        }
    }

    private var editor: some View {
        measuring
            .overlay {
                TextEditor(text: $text, selection: $selection)
                    .font(.system(size: MarkdownRenderer.bodySize))
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, Self.verticalInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focused($editorFocused)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            return .ignored
                        }
                        if !choices.isEmpty {
                            insertHighlighted()
                            return .handled
                        }
                        if !isRunning {
                            onSubmit()
                        }
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard !choices.isEmpty else { return .ignored }
                        insertHighlighted()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !choices.isEmpty, let query else { return onEscape() ? .handled : .ignored }
                        dismissed = query
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                        // Arrow keys carry the numeric pad and function flags, so only real modifiers count.
                        guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]), !choices.isEmpty else { return .ignored }
                        if press.key == .upArrow {
                            highlight = max(highlightedIndex - 1, 0)
                        } else {
                            highlight = min(highlightedIndex + 1, choices.count - 1)
                        }
                        return .handled
                    }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: MarkdownRenderer.bodySize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, Self.verticalInset)
                        .allowsHitTesting(false)
                }
            }
    }

    private var mentionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
                Button {
                    insert(choice)
                } label: {
                    HStack(spacing: 8) {
                        mark(for: choice)
                            .frame(width: 16, height: 16)
                        Text(choice.title)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    // A neutral highlight: the agents' logos keep their own colors, which a
                    // solid accent fill would clash with or hide.
                    .background {
                        if index == highlightedIndex {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.1))
                        }
                    }
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { highlight = index }
                }
            }
        }
        .padding(5)
        .frame(width: 180)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var measuring: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: MarkdownRenderer.bodySize))
            .lineLimit(text.isEmpty ? 1 : Self.maxLines)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, Self.verticalInset)
    }

    private var query: Mention.Query? {
        guard threadID == selectionThreadID,
              text.count == selectionTextCount,
              let selection,
              selection.isInsertion,
              case .selection(let range) = selection.indices else {
            return nil
        }
        return Mention.query(in: text, caret: range.lowerBound)
    }

    private var choices: [Mention.Choice] {
        guard let query, dismissed != query else { return [] }
        return Mention.choices(matching: query.letters, among: activeAgents)
    }

    private var highlightedIndex: Int {
        guard !choices.isEmpty else { return 0 }
        return min(highlight, choices.count - 1)
    }

    @ViewBuilder private func mark(for choice: Mention.Choice) -> some View {
        if let agent = AgentID(rawValue: choice.rawValue) {
            AgentMark(agent: agent, size: 15)
        } else {
            Image(systemName: "person.2")
        }
    }

    private func insertHighlighted() {
        guard choices.indices.contains(highlightedIndex) else { return }
        insert(choices[highlightedIndex])
    }

    private func insert(_ choice: Mention.Choice) {
        guard let query else { return }
        let applied = Mention.apply(choice, to: text, query: query)
        text = applied.text
        let caret = applied.text.index(applied.text.startIndex, offsetBy: applied.caret)
        selection = TextSelection(insertionPoint: caret)
        selectionTextCount = applied.text.count
        selectionThreadID = threadID
        highlight = 0
        dismissed = nil
        editorFocused = true
    }

    private func placeCaretAtEnd() {
        selection = TextSelection(insertionPoint: text.endIndex)
        selectionTextCount = text.count
        selectionThreadID = threadID
    }
}
