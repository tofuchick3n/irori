import AppKit
import PDFKit
import SwiftUI
import WebKit

/// A file opened in its own preview window.
struct PreviewTarget: Codable, Hashable {
    var url: URL
    /// The thread folder, so an HTML file can load its sibling assets.
    var folder: URL
}

/// A file rendered inside the app: markdown like the chat, HTML in a web view, PDFs, images,
/// and text in monospace. Anything else gets a large icon and an Open button.
/// Restarts the preview load when the file on disk may have changed.
struct PreviewStamp: Equatable {
    let url: URL
    let modified: Date
    let size: Int
}

struct FilePreview: View {
    let url: URL
    let folder: URL
    let stamp: PreviewStamp
    @State private var payload: PreviewPayload?

    init(file: ThreadFile, folder: URL) {
        self.url = file.url
        self.folder = folder
        self.stamp = PreviewStamp(url: file.url, modified: file.modified, size: file.size)
    }

    init(url: URL, folder: URL) {
        self.url = url
        self.folder = folder
        self.stamp = PreviewStamp(url: url, modified: .distantPast, size: 0)
    }

    var body: some View {
        Group {
            switch FileKind(url) {
            case .markdown, .csv, .code, .text, .image:
                loaded
            case .html:
                WebPreview(url: url, folder: folder)
            case .pdf:
                PDFPreview(url: url)
            case .other:
                fallback
            }
        }
        // The read, the markdown render, and the image decode all happen there, not in body.
        .task(id: stamp) {
            guard FileKind(url).loadsInBackground else { return }
            payload = nil
            let url = url, kind = FileKind(url)
            let scan = Task.detached { PreviewPayload.load(url: url, kind: kind) }
            let fresh = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled else { return }
            payload = fresh
        }
    }

    @ViewBuilder private var loaded: some View {
        if let payload {
            switch payload {
            case .attributed(let text):
                DocumentText(text: text.value)
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image.value)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: image.value.size.width)
                        .padding(16)
                }
            case .unsupported:
                fallback
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var fallback: some View {
        ContentUnavailableView {
            Label {
                Text(url.lastPathComponent)
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
            }
        } description: {
            Text("This file can't be previewed here.")
        } actions: {
            Button("Open") { NSWorkspace.shared.open(url) }
        }
    }
}

/// Styled text in its own scroll view, selectable, with the chat's code and quote drawing.
private struct DocumentText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context _: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 18, height: 16)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.textStorage?.setAttributedString(text)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context _: Context) {
        guard let view = scroll.documentView as? NSTextView, view.textStorage?.isEqual(to: text) == false else { return }
        view.textStorage?.setAttributedString(text)
    }
}

/// An HTML file in a web view. Links leave for the default browser instead of replacing the file.
private struct WebPreview: NSViewRepresentable {
    let url: URL
    let folder: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .textBackgroundColor
        view.loadFileURL(url, allowingReadAccessTo: folder)
        return view
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let target = action.request.url else { return .allow }
            await MainActor.run { _ = NSWorkspace.shared.open(target) }
            return .cancel
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context _: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_: PDFView, context _: Context) {}
}
