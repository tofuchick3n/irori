import AppKit
import SwiftUI

/// A file in a thread's folder, with the agent whose reply last created or changed it.
struct ThreadFile: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var url: URL
    var size: Int
    var modified: Date
    var agent: AgentID?

    /// Every file in the folder, newest first; dot-folders and app bundles' insides are skipped.
    static func list(in folder: URL, thread: Thread) -> [ThreadFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var authors: [String: AgentID] = [:]
        for message in thread.messages {
            guard case .agent(let agent) = message.author else { continue }
            for path in message.files {
                authors[path] = agent
            }
        }
        var files: [ThreadFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            guard let relative = relativePath(of: url, in: folder) else { continue }
            files.append(ThreadFile(
                path: relative,
                url: url,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast,
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

/// The thread's files beside the transcript: a list, and a full-height preview of the one picked.
struct FilesDrawer: View {
    let thread: Thread
    let folder: URL
    /// Changes whenever a reply may have added files, so the list reloads.
    let revision: Int
    @Binding var selection: String?
    @State private var files: [ThreadFile] = []

    var body: some View {
        Group {
            if let file = files.first(where: { $0.path == selection }) {
                FilePreviewScreen(file: file, folder: folder) {
                    selection = nil
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: selection)
        // Opaque like the transcript: documents read better on a solid page than on glass.
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: "\(thread.id)-\(revision)") {
            files = ThreadFile.list(in: folder, thread: thread)
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
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(files) { file in
                            FileRow(file: file) {
                                selection = file.path
                            }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(file.url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct FileRow: View {
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
            Text(file.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            Text("·")
            Text(Int64(file.size), format: .byteCount(style: .file))
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
