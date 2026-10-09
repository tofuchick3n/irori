import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: DeskModel
    var sidebar = SidebarControl()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var savingToTakibi: Message?
    @State private var shownFile: String?
    /// The drawer's state once its slide has finished; until then the reading column keeps its width.
    @State private var settledShowsFiles = false
    /// Opens with the files drawer showing; for snapshots.
    var startsWithFiles = false
    var startsWithFile: String?
    private static let filesWidth: CGFloat = 480
    private static let slide = Animation.smooth(duration: 0.3)

    /// A panel is sliding in or out, so the transcript and composer keep their wrapping.
    private var holdsColumn: Bool {
        model.showsFiles != settledShowsFiles || sidebar.isSliding
    }

    var body: some View {
        NavigationSplitView {
            ThreadSidebar(model: model)
                .background(SidebarControlAnchor(control: sidebar))
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button("Toggle Sidebar", systemImage: "sidebar.left", action: sidebar.toggle)
                            .help("Hide or show the sidebar (⌃⌘S)")
                    }
                }
        } detail: {
            if let thread = model.selectedThread {
                let matches = model.findMatches
                Group {
                    if thread.messages.isEmpty {
                        EmptyThreadView(model: model)
                    } else {
                        TranscriptView(
                            thread: thread,
                            streamingMessageID: model.streamingMessageID,
                            liveReply: model.liveReply,
                            modelLabel: model.catalog.label(for:agent:),
                            userName: model.profile.displayName.isEmpty ? "You" : model.profile.displayName,
                            userPhoto: model.profile.photo,
                            saveToTakibi: { savingToTakibi = $0 },
                            workspace: model.workspaceURL(for: thread.id),
                            allowedCommands: model.allowedCommands,
                            allowCommand: model.allowCommand,
                            performFix: { message in
                                model.performFix(message)
                                if message.fix == .openSettings { openSettings() }
                            },
                            waitingApprovals: Set(model.approvalWaiters.keys),
                            decide: model.decide,
                            showFile: { path in
                                shownFile = path
                                model.showsFiles = true
                            },
                            retryID: thread.messages.first { model.canRetry($0.id) }?.id,
                            editID: thread.messages.first { model.canEdit($0.id) }?.id,
                            copy: model.copy,
                            retry: model.retry,
                            edit: model.edit,
                            findMatches: matches,
                            currentMatch: model.currentFindIndex(among: matches.count).map { matches[$0] },
                            holdsWidth: holdsColumn
                        )
                        .id(thread.id)
                        // Only the drawer slides. Animated, the transcript's bottom-anchored scroll drifted.
                        .transaction(value: model.showsFiles) { $0.animation = nil }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Glass over the transcript's top edge, like the composer at its bottom.
                .safeAreaBar(edge: .top, spacing: 0) {
                    if model.isFinding {
                        ReadingColumn(holdsWidth: holdsColumn) {
                            FindBar(model: model, count: matches.count)
                        }
                        .padding(.vertical, 8)
                    }
                }
                // A bar, not an inset: the transcript scrolls under the glass composer and fades there.
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    ReadingColumn(holdsWidth: holdsColumn) {
                        VStack(spacing: 8) {
                            if let error = model.saveError {
                                SaveErrorBanner(message: error, retry: model.retrySave)
                            }
                            ComposerView(model: model)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    .transaction(value: model.showsFiles) { $0.animation = nil }
                }
                .navigationTitle(thread.title)
                .toolbar {
                    if thread.allowsEverything {
                        ToolbarItem {
                            Image(systemName: "checkmark.shield")
                                .help("Allowing everything in this thread")
                                .accessibilityLabel("Allowing everything in this thread")
                        }
                    }
                    ToolbarItem {
                        ThreadTagsButton(model: model, thread: thread)
                    }
                    ToolbarItem {
                        // A toggle, so the button shows as on while the drawer is open.
                        Toggle("Files", systemImage: "sidebar.trailing", isOn: $model.showsFiles)
                            .help(model.showsFiles ? "Hide this thread's files" : "Show the files agents made in this thread")
                    }
                }
                .inspector(isPresented: $model.showsFiles) {
                    FilesDrawer(
                        thread: thread,
                        folder: model.workspaceURL(for: thread.id),
                        revision: thread.messages.count * 2 + (model.selectedThreadIsRunning ? 1 : 0),
                        selection: $shownFile
                    )
                    // A minimum below the ideal width opened the drawer narrow, then widened it a few
                    // frames later, so the transcript rewrapped twice.
                    .inspectorColumnWidth(min: Self.filesWidth, ideal: Self.filesWidth, max: 900)
                }
                .transaction(value: model.showsFiles) { $0.animation = Self.slide }
                .onChange(of: model.showsFiles) {
                    if model.showsFiles { sidebar.makeRoom(for: Self.filesWidth) } else { sidebar.giveBackRoom() }
                }
                // Rewrap once the drawer has finished sliding.
                .task(id: model.showsFiles) {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    settledShowsFiles = model.showsFiles
                }
                .onChange(of: thread.id) {
                    shownFile = nil
                }
                // Escape outside the composer; the composer and the find bar handle their own first.
                .onExitCommand {
                    _ = model.dismissForEscape()
                }
                .onAppear {
                    if startsWithFiles { model.showsFiles = true }
                    if let startsWithFile { shownFile = startsWithFile }
                }
            } else {
                ContentUnavailableView {
                    Label("No Thread Selected", systemImage: "text.bubble")
                } description: {
                    Text("Choose a thread, or press ⌘N to start one.")
                } actions: {
                    Button("New Thread", action: model.newThread)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let error = model.saveError {
                        SaveErrorBanner(message: error, retry: model.retrySave)
                            .frame(maxWidth: TranscriptView.columnWidth)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if !model.hasSeenWelcome { openWindow(id: WelcomeView.windowID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.appBecameActive()
        }
        .sheet(item: $savingToTakibi) { message in
            SaveToTakibiSheet(model: model, message: message)
        }
        .alert("Rename Thread", isPresented: $model.isRenaming) {
            TextField("Title", text: $model.renameText)
            Button("Rename") {
                model.commitRename()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct SaveErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again", action: retry)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The open thread's client tags, shown as logos, with a menu to change them.
private struct ThreadTagsButton: View {
    var model: DeskModel
    let thread: Thread
    @State private var isAddingTag = false
    @State private var newTagName = ""

    var body: some View {
        Menu {
            ForEach(model.allTags, id: \.self) { tag in
                Toggle(isOn: Binding(
                    get: { thread.tags.contains(tag) },
                    set: { _ in model.toggleTag(tag, on: thread.id) }
                )) {
                    Label {
                        Text(tag)
                    } icon: {
                        ClientMark.menuImage(model.logo(for: tag))
                    }
                }
            }
            Divider()
            Button("New Tag…") {
                newTagName = ""
                isAddingTag = true
            }
        } label: {
            if let tag = thread.tags.first {
                Label {
                    Text(thread.tags.count > 1 ? "\(tag) +\(thread.tags.count - 1)" : tag)
                } icon: {
                    ClientMark.menuImage(model.logo(for: tag))
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label("Tag", systemImage: "tag")
            }
        }
        .help("Client tags for this thread")
        .alert("New Tag", isPresented: $isAddingTag) {
            TextField("Client or topic", text: $newTagName)
            Button("Add") {
                model.addTag(named: newTagName, to: thread.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Asks an agent, in the thread, to attach a reply to a Takibi card.
private struct SaveToTakibiSheet: View {
    var model: DeskModel
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @State private var card = ""
    @State private var agent: AgentID = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save to Takibi")
                .font(.headline)
            Text("An agent attaches this reply to a card as a markdown note. You'll see the request and its answer in the thread.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Card", text: $card, prompt: Text("Card ID or link"))
                Picker("Ask", selection: $agent) {
                    ForEach(model.activeAgents, id: \.self) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
            }
            if model.isRunning {
                Text("Wait for the current reply to finish first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Ask \(agent.displayName)") {
                    model.requestTakibiSave(messageID: message.id, card: card, agent: agent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(card.trimmingCharacters(in: .whitespaces).isEmpty || model.isRunning)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if case .agent(let author) = message.author, model.activeAgents.contains(author) {
                agent = author
            } else if let first = model.activeAgents.first {
                agent = first
            }
        }
    }
}
