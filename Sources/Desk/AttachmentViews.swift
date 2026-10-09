import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Pending attachments above the composer's text, each with a remove button.
struct AttachmentChips: View {
    let urls: [URL]
    let remove: (URL) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(urls, id: \.self) { url in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Remove", systemImage: "xmark.circle.fill") { remove(url) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(url.lastPathComponent)")
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sent message's attachments: images as thumbnails, everything else as file chips. Both open the preview.
struct MessageAttachments: View {
    let paths: [String]
    let folder: URL
    let show: (String) -> Void

    var body: some View {
        let images = paths.filter(Attachments.isImage)
        let files = paths.filter { !Attachments.isImage($0) }
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(images, id: \.self) { path in
                        AttachmentThumbnail(url: folder.appending(path: path, directoryHint: .notDirectory)) { show(path) }
                    }
                }
            }
            if !files.isEmpty {
                FileChips(files: files, folder: folder, show: show)
            }
        }
    }
}

private struct AttachmentThumbnail: View {
    let url: URL
    let show: () -> Void
    @State private var image: NSImage?

    private nonisolated static let side: CGFloat = 96

    var body: some View {
        Button(action: show) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.primary.opacity(0.06)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Preview \(url.lastPathComponent)")
        .task(id: url) {
            image = await Self.thumbnail(of: url)
        }
    }

    private nonisolated static func thumbnail(of url: URL) async -> NSImage? {
        await Task.detached {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side * 2,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: .zero)
        }.value
    }
}

/// Files and images from a paste. Image data with no file is saved to a temporary file first.
enum PastedFiles {
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
               let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                var data = await data(of: provider, type: .png)
                if data == nil { data = await self.data(of: provider, type: .image) }
                if let data, let url = save(data) { urls.append(url) }
            }
        }
        return urls
    }

    private static func data(of provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func save(_ data: Data) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let url = directory.appending(path: "Pasted Image.png", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
