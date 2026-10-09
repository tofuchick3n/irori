import SwiftUI

struct ThreadSidebar: View {
    @Bindable var model: DeskModel
    @State private var newTagThread: Thread.ID?
    @State private var newTagName = ""

    var body: some View {
        List(selection: $model.selection) {
            Section {
                ForEach(model.visibleThreads) { thread in
                    ThreadRow(
                        thread: thread,
                        isRunning: model.runningThreadID == thread.id,
                        isUnread: model.unreadThreads.contains(thread.id),
                        logo: model.logo(for:)
                    )
                        .tag(thread.id)
                        .contextMenu {
                            TagsMenu(model: model, threadID: thread.id) {
                                newTagName = ""
                                newTagThread = thread.id
                            }
                            Divider()
                            Button("Rename…") {
                                model.beginRename(thread.id)
                            }
                            if thread.archivedAt == nil {
                                Button("Archive") {
                                    model.archive(thread.id)
                                }
                                .disabled(model.runningThreadID == thread.id)
                            } else {
                                Button("Unarchive") {
                                    model.unarchive(thread.id)
                                }
                            }
                            if !thread.allowedRules.isEmpty || thread.allowsEverything {
                                Button("Reset Permissions for This Thread") {
                                    model.resetThreadPermissions(thread.id)
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                model.delete(thread.id)
                            }
                        }
                }
            } header: {
                if model.showsArchived {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                        Text("Archived")
                        Spacer()
                        Button("Show Active") {
                            model.showsArchived = false
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                } else if let filter = model.tagFilter {
                    HStack(spacing: 6) {
                        ClientMark(tag: filter, logo: model.logo(for: filter), size: 14)
                        Text(filter)
                        Spacer()
                        Button("Show All") {
                            model.tagFilter = nil
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
        .overlay {
            if model.visibleThreads.isEmpty, !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                FilterMenu(model: model)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem {
                Button("New Thread", systemImage: "square.and.pencil") {
                    model.newThread()
                }
                .help("New Thread (⌘N)")
            }
        }
        .alert("New Tag", isPresented: Binding(get: { newTagThread != nil }, set: { if !$0 { newTagThread = nil } })) {
            TextField("Client or topic", text: $newTagName)
            Button("Add") {
                if let id = newTagThread {
                    model.addTag(named: newTagName, to: id)
                }
                newTagThread = nil
            }
            Button("Cancel", role: .cancel) {
                newTagThread = nil
            }
        }
    }
}

/// Picks which client's threads the sidebar shows.
private struct FilterMenu: View {
    @Bindable var model: DeskModel

    var body: some View {
        Menu {
            Picker("Show", selection: $model.tagFilter) {
                Text("All Threads").tag(String?.none)
                Divider()
                ForEach(model.allTags, id: \.self) { tag in
                    Label {
                        Text(tag)
                    } icon: {
                        ClientMark.menuImage(model.logo(for: tag))
                    }
                    .tag(Optional(tag))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(isOn: $model.showsArchived) {
                Label("Show Archived (\(model.archivedCount))", systemImage: "archivebox")
            }
            .disabled(model.archivedCount == 0 && !model.showsArchived)
        } label: {
            Label(model.tagFilter ?? "All Threads", systemImage: model.tagFilter == nil
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter threads by client")
    }
}

/// Toggles for every known tag on one thread, plus a way to add a new one.
struct TagsMenu: View {
    var model: DeskModel
    let threadID: Thread.ID
    let newTag: () -> Void

    var body: some View {
        Menu("Tags") {
            ForEach(model.allTags, id: \.self) { tag in
                Toggle(isOn: Binding(
                    get: { model.threads.first { $0.id == threadID }?.tags.contains(tag) ?? false },
                    set: { _ in model.toggleTag(tag, on: threadID) }
                )) {
                    Label {
                        Text(tag)
                    } icon: {
                        ClientMark.menuImage(model.logo(for: tag))
                    }
                }
            }
            Divider()
            Button("New Tag…", action: newTag)
        }
    }
}

private struct ThreadRow: View {
    let thread: Thread
    let isRunning: Bool
    let isUnread: Bool
    let logo: (String) -> NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(thread.title)
                    .lineLimit(1)
                if thread.allowsEverything {
                    Image(systemName: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Allowing everything in this thread")
                        .accessibilityLabel("Allowing everything in this thread")
                }
                Spacer(minLength: 0)
                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Replying")
                } else if isUnread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Unread")
                }
            }
            HStack(spacing: 4) {
                if thread.messages.isEmpty {
                    Text("No messages")
                } else {
                    Text(thread.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
                Spacer(minLength: 8)
                if let first = thread.tags.first {
                    Text(thread.tags.count > 1 ? "\(first) +\(thread.tags.count - 1)" : first)
                    HStack(spacing: -3) {
                        ForEach(thread.tags.prefix(3), id: \.self) { tag in
                            ClientMark(tag: tag, logo: logo(tag), size: 14)
                        }
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 5)
    }
}

/// A client's logo for a tag, or a plain tag glyph when there's no logo.
struct ClientMark: View {
    let tag: String
    let logo: NSImage?
    let size: CGFloat

    var body: some View {
        if let logo {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityLabel(tag)
        } else {
            Image(systemName: "tag")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityLabel(tag)
        }
    }

    /// Menus and toolbars draw images at their own size and shape, so hand them a round, pre-sized copy.
    static func menuImage(_ logo: NSImage?) -> Image {
        guard let logo else {
            return Image(systemName: "tag")
        }
        let round = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            logo.draw(in: rect)
            return true
        }
        return Image(nsImage: round)
    }
}
