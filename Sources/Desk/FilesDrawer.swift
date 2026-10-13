import AppKit
import SwiftUI

/// A file in a thread's folder, with the agent whose reply last created or changed it.
struct ThreadFile: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var url: URL
    var size: Int
    var modified: Date
    /// Formatted once at scan time, so rows don't reformat on every update.
    var modifiedText: String
    var sizeText: String
    var agent: AgentID?

    /// Which agent's reply last touched each path; later replies win.
    static func authors(in messages: [Message]) -> [String: AgentID] {
        var authors: [String: AgentID] = [:]
        for message in messages {
            guard case .agent(let agent) = message.author else { continue }
            for path in message.files {
                authors[path] = agent
            }
        }
        return authors
    }

    /// Every file in the folder, newest first; dot-folders and app bundles' insides are skipped.
    /// Nil when cancelled, so an older revision's walk never replaces a newer list.
    static func list(in folder: URL, authors: [String: AgentID]) -> [ThreadFile]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let dates = RelativeDateTimeFormatter()
        dates.dateTimeStyle = .named
        dates.unitsStyle = .abbreviated
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        let now = Date.now
        var files: [ThreadFile] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return nil }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path(percentEncoded: false)
            guard full.hasPrefix(prefix), full.count > prefix.count else { continue }
            let relative = String(full.dropFirst(prefix.count))
            let modified = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            files.append(ThreadFile(
                path: relative,
                url: url,
                size: size,
                modified: modified,
                modifiedText: modified == .distantPast ? "—" : dates.localizedString(for: modified, relativeTo: now),
                sizeText: bytes.string(fromByteCount: Int64(size)),
                agent: authors[relative]
            ))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    /// The file's path inside the folder, or nil when it lies outside.
    static func relativePath(of url: URL, in folder: URL) -> String? {
        guard url.isFileURL else { return nil }
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

/// What the list scan is keyed on: a new folder or revision rescans.
private struct ScanID: Equatable {
    let folder: URL
    let revision: Int
}

/// The thread's files beside the transcript: a list, and a full-height preview of the one picked.
///
/// Compared on its inputs, so text streaming into the transcript doesn't rebuild the list.
struct FilesDrawer: View, Equatable {
    nonisolated static func == (lhs: FilesDrawer, rhs: FilesDrawer) -> Bool {
        lhs.folder == rhs.folder
            && lhs.revision == rhs.revision
            && lhs.authors == rhs.authors
            && lhs._selection.wrappedValue == rhs._selection.wrappedValue
    }

    let folder: URL
    /// Changes whenever a reply may have added files, so the list reloads.
    let revision: Int
    /// Which agent's reply last created or changed each path.
    let authors: [String: AgentID]
    @Binding var selection: String?
    @State private var files: [ThreadFile] = []

    var body: some View {
        // Hoisted, so the list leaves the accessibility tree only while a preview covers it.
        let previewed = files.first(where: { $0.path == selection })
        return ZStack {
            // Stays mounted under the preview, so going back keeps the rows and the scroll position.
            list
                .accessibilityHidden(previewed != nil)
            if let file = previewed {
                FilePreviewScreen(file: file, folder: folder) {
                    selection = nil
                }
                .background(Color(nsColor: .textBackgroundColor))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: selection)
        // Opaque like the transcript: documents read better on a solid page than on glass.
        .background(Color(nsColor: .textBackgroundColor))
        // Off the main thread: the drawer opens with this, and a scan there dropped its first frames.
        // Cancelling the detached walk, so a newer revision stops an older one mid-enumeration.
        .task(id: ScanID(folder: folder, revision: revision)) {
            let folder = folder, authors = authors
            let scan = Task.detached { ThreadFile.list(in: folder, authors: authors) }
            let fresh = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled, let fresh else { return }
            files = fresh
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files")
                    .font(.headline)
                if !files.isEmpty {
                    Text("\(files.count)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Folder", systemImage: "folder") {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Open this thread's folder in Finder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if files.isEmpty {
                ContentUnavailableView(
                    "No Files Yet",
                    systemImage: "doc.on.doc",
                    description: Text("Files agents create in this thread show up here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(files) { file in
                    FileRow(file: file) {
                        selection = file.path
                    }
                    .equatable()
                    .contextMenu {
                        Button("Open") { NSWorkspace.shared.open(file.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Compared on the file, so a list update leaves untouched rows alone.
private struct FileRow: View, Equatable {
    nonisolated static func == (lhs: FileRow, rhs: FileRow) -> Bool {
        lhs.file == rhs.file
    }

    let file: ThreadFile
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileKindIcon(kind: FileKind(file.url))
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FileSubtitle(file: file)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .help(file.path)
    }
}

private struct FileSubtitle: View {
    let file: ThreadFile

    var body: some View {
        HStack(spacing: 4) {
            if let agent = file.agent {
                AgentMark(agent: agent, size: 11)
                Text(agent.displayName)
                Text("·")
            }
            Text(file.modifiedText)
            Text("·")
            Text(file.sizeText)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// A file's type, from its extension, for picking an icon and a previewer.
enum FileKind: Equatable {
    case markdown, html, pdf, image, csv, code, text, other

    init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdx": self = .markdown
        case "html", "htm": self = .html
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg": self = .image
        case "csv", "tsv": self = .csv
        case "json", "yaml", "yml", "toml", "xml", "js", "ts", "py", "swift", "sh", "css", "sql": self = .code
        case "txt", "log", "": self = .text
        default: self = .other
        }
    }

    /// Kinds whose content the preview loads in a background task; HTML and PDF views load their own.
    var loadsInBackground: Bool {
        switch self {
        case .markdown, .csv, .code, .text, .image: true
        case .html, .pdf, .other: false
        }
    }

    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .html: "globe"
        case .pdf: "doc.text.image"
        case .image: "photo"
        case .csv: "tablecells"
        case .code: "curlybraces"
        case .text: "doc.plaintext"
        case .other: "doc"
        }
    }

    var tint: Color {
        switch self {
        case .markdown: .blue
        case .html: .orange
        case .pdf: .red
        case .image: .purple
        case .csv: .green
        case .code: .teal
        case .text, .other: .gray
        }
    }
}

struct FileKindIcon: View {
    let kind: FileKind
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(kind.tint)
            .frame(width: size, height: size)
            .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// One file, full height: a header with back, name, Open, and Show in Finder over its preview.
private struct FilePreviewScreen: View {
    let file: ThreadFile
    let folder: URL
    let back: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("All files")
                FileKindIcon(kind: FileKind(file.url), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text((file.path as NSString).lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    FileSubtitle(file: file)
                }
                Spacer(minLength: 4)
                Button("Open in Window", systemImage: "macwindow") {
                    openWindow(value: PreviewTarget(url: file.url, folder: folder))
                }
                .help("Preview in its own window")
                Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(file.url) }
                    .help("Open with its default app")
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    .help("Show in Finder")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            FilePreview(file: file, folder: folder)
                .id(file.url)
        }
    }
}
