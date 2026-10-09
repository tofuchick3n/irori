import AppKit
import SwiftUI

/// What an agent did on its way to a reply: a live, shimmering current step and timer while it
/// works, then "Worked for 1m 12s · 6 steps", which expands to every step and any thinking text.
struct WorkLogView: View {
    let message: Message
    /// Allows folded in from older saves, which stored the card instead of a step.
    var leadingSteps: [WorkStep] = []
    let isStreaming: Bool
    @State private var isExpanded = false

    private var steps: [WorkStep] { leadingSteps + message.steps }

    /// Thinking arrives as markdown, mostly bold titles; it shows styled, line breaks kept. Bold
    /// titles saved back to back, as "**One****Two**", go on lines of their own.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let separated = text.replacingOccurrences(of: "****", with: "**\n\n**")
        return (try? AttributedString(markdown: separated, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    if isStreaming {
                        Image(systemName: "sparkle")
                            .foregroundStyle(.secondary)
                        ShimmerText(text: currentTitle)
                    } else {
                        Text(summary)
                            .foregroundStyle(.secondary)
                    }
                    if isStreaming, let startedAt = message.startedAt {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        ElapsedTime(since: startedAt)
                    }
                    if !steps.isEmpty || !message.thinking.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.snappy(duration: 0.2), value: isExpanded)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)

            // Opens without animating: in the bottom-anchored transcript, rows sliding in drew over
            // the messages above them.
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps) { step in
                        StepRow(step: step)
                    }
                    if !message.thinking.isEmpty {
                        ScrollView {
                            Text(Self.inlineMarkdown(message.thinking))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                        .padding(.top, 4)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 2)
    }

    private var currentTitle: String {
        steps.last(where: { $0.state == .running })?.liveTitle
            ?? (message.body.isEmpty ? "Thinking" : "Writing")
    }

    private var summary: String {
        let count = steps.count
        let steps = count == 1 ? "1 step" : "\(count) steps"
        guard let start = message.startedAt, let end = message.finishedAt else { return steps }
        return "Worked for \(ElapsedTime.format(end.timeIntervalSince(start))) · \(steps)"
    }
}

private struct StepRow: View {
    let step: WorkStep

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch step.state {
                case .running:
                    ProgressView()
                        .controlSize(.mini)
                case .done:
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 14)
            Image(systemName: symbol)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(step.liveTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            if let end = step.endedAt {
                Text(ElapsedTime.format(end.timeIntervalSince(step.startedAt)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(step.detail ?? step.title)
    }

    private var symbol: String {
        switch step.kind {
        case .thinking: "brain"
        case .command: "terminal"
        case .fileWrite: "square.and.pencil"
        case .fileRead: "doc.text"
        case .tool: "wrench.and.screwdriver"
        case .approval: "checkmark.shield"
        }
    }
}

/// A once-a-second clock: "42s", "1m 12s".
struct ElapsedTime: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.tertiary)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total)s" }
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }
}

/// Markdown that shows text as it streams in. A burst, like a CLI that sends a whole paragraph at
/// once, is revealed at a steady pace so it still reads as streaming; text that arrives steadily
/// shows as it comes, since each reveal step re-renders the reply. Text already present when the
/// view appears shows at once.
struct StreamingMarkdown: View {
    let text: String
    let isStreaming: Bool
    var menuItems: [NSMenuItem] = []
    var highlights: [NSRange] = []
    var current: NSRange?
    var openLink: ((URL) -> Bool)?
    @State private var shown: Int
    @State private var expandedCode: Set<Int> = []
    /// More new characters than this at once are revealed gradually.
    private static let burst = 200

    init(
        text: String,
        isStreaming: Bool,
        menuItems: [NSMenuItem] = [],
        highlights: [NSRange] = [],
        current: NSRange? = nil,
        openLink: ((URL) -> Bool)? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.menuItems = menuItems
        self.highlights = highlights
        self.current = current
        self.openLink = openLink
        _shown = State(initialValue: text.count)
    }

    var body: some View {
        MarkdownText(
            markdown: shown >= text.count ? text : String(text.prefix(shown)),
            menuItems: menuItems,
            highlights: highlights,
            current: current,
            openLink: openLink,
            // Find ranges count every code line, so a message with matches shows its code in full.
            folding: highlights.isEmpty ? .init(streaming: isStreaming, expanded: expandedCode) : nil,
            toggleCode: { expandedCode.formSymmetricDifference([$0]) }
        )
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: text.count) {
                if text.count - shown <= Self.burst {
                    shown = text.count
                    return
                }
                while shown < text.count {
                    let backlog = text.count - shown
                    // Catch up within about half a second however large the burst. Each step
                    // re-renders and lays out the reply, so steps come at a steady 60 ms.
                    shown = min(text.count, shown + max(6, backlog / 6))
                    try? await Task.sleep(for: .milliseconds(60))
                    if Task.isCancelled { return }
                }
            }
    }
}

/// Files an agent created or changed in this turn; a click shows one in the files drawer.
struct FileChips: View {
    let files: [String]
    let folder: URL
    let show: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(files, id: \.self) { path in
                FileChip(url: folder.appending(path: path, directoryHint: .notDirectory), name: path) {
                    show(path)
                }
            }
        }
    }
}

private struct FileChip: View {
    let url: URL
    let name: String
    let show: () -> Void

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        Button(action: show) {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(!exists)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .help(exists ? "Preview \(name)" : "This file no longer exists")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

/// "Claude isn't signed in. [Sign In]"
struct FixNotice: View {
    let message: Message
    let fix: Fix
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                Image(systemName: "exclamationmark.triangle")
                Text(message.body)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button(fix == .signIn ? "Sign In" : "Open Settings", action: perform)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

/// "Claude was refused python3. [Allow python3] [Show Command]"
struct DeniedNotice: View {
    let message: Message
    let allowedCommands: [String]
    let allowCommand: (String) -> Void
    @State private var showsCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    Image(systemName: "hand.raised")
                    Text(message.body)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                ForEach(message.deniedPrograms.filter { !allowedCommands.contains($0) }, id: \.self) { program in
                    Button("Allow \(program)") {
                        allowCommand(program)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Let Claude run \(program) from now on. You can remove it in Settings → Permissions.")
                }
                if message.deniedCommand != nil {
                    Button(showsCommand ? "Hide Command" : "Show Command") {
                        showsCommand.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if showsCommand, let command = message.deniedCommand {
                Text(command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var items: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.items.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
