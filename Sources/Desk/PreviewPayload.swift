import AppKit
import ImageIO

/// A file's preview content, read and rendered off the main thread; the view only shows it.
enum PreviewPayload: Sendable {
    case attributed(Shared<NSAttributedString>)
    case image(Shared<NSImage>)
    case unsupported

    /// Built once on a background task, then only read.
    struct Shared<Value>: @unchecked Sendable {
        let value: Value
    }

    /// Bigger text files open in their own app; reading megabytes into a text view stalls.
    static let textLimit = 300_000
    /// Images downsample to this many pixels on their long edge, for a ~480pt panel at 2x.
    private static let thumbnailMaxPixels = 960

    static func load(url: URL, kind: FileKind) -> PreviewPayload {
        switch kind {
        case .markdown, .csv, .code, .text:
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= textLimit else { return .unsupported }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .unsupported }
            guard !Task.isCancelled else { return .unsupported }
            let styled = kind == .markdown ? MarkdownRenderer.render(text) : monospaced(text)
            return .attributed(Shared(value: styled))
        case .image:
            if let thumbnail = thumbnail(url) {
                return .image(Shared(value: thumbnail))
            }
            // Formats ImageIO can't thumbnail, like SVG, decode whole; they're small.
            if let full = NSImage(contentsOf: url) {
                return .image(Shared(value: full))
            }
            return .unsupported
        case .html, .pdf, .other:
            return .unsupported
        }
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixels,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        // Points, not pixels: at 2x a 960px thumbnail fills the 480pt panel.
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    private static func monospaced(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize * 0.92, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
