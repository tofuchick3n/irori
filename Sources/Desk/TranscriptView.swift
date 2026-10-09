import SwiftUI

struct TranscriptView: View {
    /// Reading width for the transcript and the composer under it.
    static let columnWidth: CGFloat = ReadingColumn.columnWidth
    private static let topMargin: CGFloat = 20

    let thread: Thread
    let streamingMessageID: Message.ID?
    var liveReply: LiveReply?
    let modelLabel: (String, AgentID) -> String
    let userName: String
    let userPhoto: NSImage?
    let saveToTakibi: (Message) -> Void
    let workspace: URL
    var queued: QueuedMessage?
    var sendQueuedNow: () -> Void = {}
    var cancelQueued: () -> Void = {}
    let allowedCommands: [String]
    let allowCommand: (String) -> Void
    var performFix: (Message) -> Void = { _ in }
    var waitingApprovals: Set<Message.ID> = []
    var decide: (Message.ID, ApprovalDecision) -> Void = { _, _ in }
    var showFile: (String) -> Void = { _ in }
    var retryID: Message.ID?
    var editID: Message.ID?
    var copy: (Message, Bool) -> Void = { _, _ in }
    var retry: (Message.ID) -> Void = { _ in }
    var edit: (Message.ID) -> Void = { _ in }
    var findMatches: [FindMatch] = []
    var currentMatch: FindMatch?
    /// Set while a sidebar or the files drawer slides, so replies keep their wrapping.
    var holdsWidth = false
    @State private var scroll = ScrollAnchor.Box()
    @State private var visibleHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { reader in
            transcript
                .onChange(of: currentMatch) {
                    if let currentMatch {
                        reader.scrollTo(currentMatch.messageID, anchor: .center)
                    }
                }
        }
        // A panel sliding animates the scroll view's width, which leaves SwiftUI's bottom anchor a
        // margin short of the end. Someone reading the latest reply stays on it through the slide
        // and the rewrap after.
        .onChange(of: holdsWidth) { _, holds in
            scroll.holdChanged(holds)
        }
    }

    private var transcript: some View {
        ScrollView {
            // Lazy, so a streaming reply growing doesn't re-measure every message in the thread.
            // Rows not yet measured have estimated heights, so scrolling up through a long
            // thread can shift a little as they come into view.
            // A short thread fills the height with its messages at the bottom. Placed there by
            // offsetting the scroll instead, it brought the toolbar edge's line down to its top.
            ReadingColumn(holdsWidth: holdsWidth, minHeight: max(visibleHeight - Self.topMargin, 0)) {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(TranscriptRows.rows(in: thread.messages)) { row in
                        MessageRow(
                            saved: row.message,
                            leadingSteps: row.approvalSteps,
                            live: liveReply?.id == row.message.id ? liveReply : nil,
                            isStreaming: row.message.id == streamingMessageID,
                            modelLabel: modelLabel,
                            userName: userName,
                            userPhoto: userPhoto,
                            workspace: workspace,
                            allowedCommands: allowedCommands,
                            allowCommand: allowCommand,
                            isWaiting: waitingApprovals.contains(row.message.id),
                            decide: { decide(row.message.id, $0) },
                            performFix: { performFix(row.message) },
                            saveToTakibi: { saveToTakibi(row.message) },
                            showFile: showFile,
                            canRetry: row.message.id == retryID,
                            canEdit: row.message.id == editID,
                            copy: { copy(row.message, $0) },
                            retry: { retry(row.message.id) },
                            edit: { edit(row.message.id) },
                            highlights: findMatches.filter { $0.messageID == row.message.id }.map(\.range),
                            currentHighlight: currentMatch?.messageID == row.message.id ? currentMatch?.range : nil
                        )
                        .equatable()
                        .id(row.message.id)
                    }
                    if let queued {
                        QueuedMessageRow(queued: queued, userName: userName, userPhoto: userPhoto, sendNow: sendQueuedNow, cancel: cancelQueued)
                            .id(queued.id)
                    }
                    // The bottom margin, inside the stack: anchored to the bottom, the scroll view
                    // keeps the last row in place as widths change, and padding outside it drifted.
                    Color.clear
                        .frame(height: 1)
                }
                .background(ScrollAnchor(box: scroll))
            }
            .padding(.top, Self.topMargin)
        }
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
            visibleHeight = height
        }
    }
}

/// Finds the AppKit scroll view under the transcript, whose offsets are exact where SwiftUI's
/// scroll position is not.
private struct ScrollAnchor: NSViewRepresentable {
    @MainActor
    final class Box {
        weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var pinning = 0

        private var bottom: CGFloat? {
            guard let scrollView, let document = scrollView.documentView else { return nil }
            return document.frame.height - scrollView.contentView.bounds.height + scrollView.contentInsets.bottom
        }

        var isAtBottom: Bool {
            guard let bottom, let scrollView else { return true }
            return scrollView.contentView.bounds.minY >= bottom - 40
        }

        /// Pins the transcript to its end from the start of a slide until just after its rewrap.
        func holdChanged(_ holds: Bool) {
            pinning += 1
            let generation = pinning
            if holds {
                if isAtBottom { pin() } else { unpin() }
            } else if !observers.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.pinning == generation { self?.unpin() }
                    }
                }
            }
        }

        private func pin() {
            guard observers.isEmpty, let scrollView, let document = scrollView.documentView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            // Delivered as the offset or height changes, so a drift is undone before it's drawn.
            observers = [
                (NSView.boundsDidChangeNotification, scrollView.contentView),
                (NSView.frameDidChangeNotification, document),
            ].map { name, view in
                NotificationCenter.default.addObserver(forName: name, object: view, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollToBottom() }
                }
            }
            scrollToBottom()
        }

        private func unpin() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        func scrollToBottom() {
            guard let bottom, let scrollView, abs(scrollView.contentView.bounds.minY - bottom) > 0.5 else { return }
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: bottom))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    let box: Box

    func makeNSView(context _: Context) -> NSView {
        AnchorView(box: box)
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class AnchorView: NSView {
        let box: Box

        init(box: Box) {
            self.box = box
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box.scrollView = enclosingScrollView
        }
    }
}

/// Compared on its data, so a reply streaming into one row doesn't redraw every other row.
private struct MessageRow: View, Equatable {
    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.saved == rhs.saved
            && lhs.leadingSteps == rhs.leadingSteps
            && lhs.live === rhs.live
            && lhs.isStreaming == rhs.isStreaming
            && lhs.userName == rhs.userName
            && lhs.userPhoto === rhs.userPhoto
            && lhs.workspace == rhs.workspace
            && lhs.allowedCommands == rhs.allowedCommands
            && lhs.isWaiting == rhs.isWaiting
            && lhs.canRetry == rhs.canRetry
            && lhs.canEdit == rhs.canEdit
            && lhs.highlights == rhs.highlights
            && lhs.currentHighlight == rhs.currentHighlight
    }

    let saved: Message
    /// Allows from an older save, shown at the front of this reply's work log.
    var leadingSteps: [WorkStep] = []
    /// Text streamed in since `saved`, while this is the reply being written.
    let live: LiveReply?
    let isStreaming: Bool
    let modelLabel: (String, AgentID) -> String
    let userName: String
    let userPhoto: NSImage?
    let workspace: URL
    let allowedCommands: [String]
    let allowCommand: (String) -> Void
    let isWaiting: Bool
    let decide: (ApprovalDecision) -> Void
    let performFix: () -> Void
    let saveToTakibi: () -> Void
    let showFile: (String) -> Void
    let canRetry: Bool
    let canEdit: Bool
    let copy: (Bool) -> Void
    let retry: () -> Void
    let edit: () -> Void
    let highlights: [NSRange]
    let currentHighlight: NSRange?

    private var message: Message {
        live?.shown(saved) ?? saved
    }

    /// Context menu items in order; the text view's own menu shows the same list.
    private var actions: [(title: String, run: () -> Void)] {
        guard !message.body.isEmpty else { return [] }
        var items: [(title: String, run: () -> Void)] = [("Copy", { copy(false) })]
        let isAgent = if case .agent = message.author { true } else { false }
        if isAgent { items.append(("Copy Markdown", { copy(true) })) }
        if canRetry { items.append(("Retry", retry)) }
        if isAgent { items.append(("Save to Takibi…", saveToTakibi)) }
        if canEdit { items.append(("Edit", edit)) }
        return items
    }

    var body: some View {
        content.contextMenu {
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].title, action: actions[index].run)
            }
        }
    }

    /// A link to a file in this thread's folder previews it in the files drawer.
    private func showLinkedFile(_ url: URL) -> Bool {
        guard let path = ThreadFile.relativePath(of: url, in: workspace),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        showFile(path)
        return true
    }

    @ViewBuilder
    private var content: some View {
        switch message.author {
        case .notice:
            Group {
                if let approval = message.approval {
                    ApprovalCard(record: approval, isWaiting: isWaiting, decide: decide)
                } else if let fix = message.fix {
                    FixNotice(message: message, fix: fix, perform: performFix)
                } else if message.deniedPrograms.isEmpty && message.deniedCommand == nil {
                    Text(message.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    DeniedNotice(message: message, allowedCommands: allowedCommands, allowCommand: allowCommand)
                }
            }
            .padding(.leading, Avatar.size + 12)
        case .user:
            row(avatar: Avatar(kind: .user(userPhoto)), name: userName, model: nil)
        case .agent(let agent):
            row(avatar: Avatar(kind: .agent(agent)), name: agent.displayName, model: message.model.map { modelLabel($0, agent) })
        }
    }

    private func row(avatar: Avatar, name: String, model: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .fontWeight(.semibold)
                    if let model {
                        Text(model)
                            .foregroundStyle(.secondary)
                    }
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: MarkdownRenderer.bodySize))
                if case .agent = message.author, isStreaming || !message.steps.isEmpty || !leadingSteps.isEmpty {
                    WorkLogView(message: message, leadingSteps: leadingSteps, isStreaming: isStreaming)
                        .padding(.top, 2)
                }
                if !message.body.isEmpty {
                    StreamingMarkdown(
                        text: message.body,
                        isStreaming: isStreaming,
                        // Right-clicking the text shows the text view's menu, not the row's.
                        menuItems: actions.map { ClosureMenuItem($0.title, handler: $0.run) },
                        highlights: highlights,
                        current: currentHighlight,
                        openLink: showLinkedFile
                    )
                }
                if !message.attachments.isEmpty {
                    MessageAttachments(paths: message.attachments, folder: workspace, show: showFile)
                        .padding(.top, 6)
                }
                if !message.files.isEmpty {
                    FileChips(files: message.files, folder: workspace, show: showFile)
                        .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An agent's logo or the user's photo, at one size everywhere in the transcript.
struct Avatar: View {
    enum Kind {
        case user(NSImage?)
        case agent(AgentID)
    }

    static let size: CGFloat = 28

    let kind: Kind

    var body: some View {
        switch kind {
        case .user(let photo):
            UserPhoto(image: photo, size: Self.size)
        case .agent(let agent):
            AgentMark(agent: agent, size: 22)
                .frame(width: Self.size, height: Self.size)
        }
    }
}

struct AgentMark: View {
    let agent: AgentID
    let size: CGFloat

    var body: some View {
        Image(nsImage: AgentLogo.image(for: agent))
            .resizable()
            .renderingMode(agent == .grok ? .template : .original)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .accessibilityLabel(agent.displayName)
    }
}

/// The user's photo from their profile, else a plain person glyph.
struct UserPhoto: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("You")
    }
}
