import AppKit
import Foundation
import OpenDirectory

enum DeskImageError: LocalizedError {
    case unreadable

    var errorDescription: String? { "The image couldn't be read." }
}

@MainActor
enum ScaledImage {
    static func jpeg(from url: URL, longestSide: CGFloat) throws -> Data {
        guard let image = NSImage(contentsOf: url) else { throw DeskImageError.unreadable }
        let source = image.size
        guard source.width > 0, source.height > 0 else { throw DeskImageError.unreadable }
        let scale = longestSide / max(source.width, source.height)
        let width = max(1, Int((source.width * scale).rounded()))
        let height = max(1, Int((source.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw DeskImageError.unreadable
        }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw DeskImageError.unreadable }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: source),
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw DeskImageError.unreadable
        }
        return data
    }

    static func png(from url: URL) throws -> Data {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw DeskImageError.unreadable
        }
        return png
    }
}

@MainActor
enum AccountPicture {
    /// The current user's Open Directory JPEG, or the picture path, or nil when either lookup fails.
    static func load() -> NSImage? {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let query = try ODQuery(
                node: node,
                forRecordTypes: kODRecordTypeUsers,
                attribute: kODAttributeTypeRecordName,
                matchType: ODMatchType(kODMatchEqualTo),
                queryValues: NSUserName(),
                returnAttributes: [kODAttributeTypeJPEGPhoto as String, kODAttributeTypePicture as String],
                maximumResults: 1
            )
            let results = try query.resultsAllowingPartial(false)
            for case let record as ODRecord in results {
                if let image = jpegPhoto(from: record) ?? picture(from: record) {
                    return image
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func jpegPhoto(from record: ODRecord) -> NSImage? {
        guard let values = try? record.values(forAttribute: kODAttributeTypeJPEGPhoto) else { return nil }
        for value in values {
            if let data = value as? Data, let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    private static func picture(from record: ODRecord) -> NSImage? {
        guard let values = try? record.values(forAttribute: kODAttributeTypePicture) else { return nil }
        for value in values {
            guard let path = value as? String else { continue }
            if let image = NSImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }
}

@MainActor
@Observable
final class UserProfile {
    var displayName: String {
        didSet { defaults.set(displayName, forKey: Self.nameKey) }
    }

    private(set) var photo: NSImage?

    private let folder: URL
    private let defaults: UserDefaults
    private let accountPicture: @MainActor () -> NSImage?

    init(
        folder: URL,
        defaults: UserDefaults = .standard,
        accountPicture: @escaping @MainActor () -> NSImage? = { nil }
    ) {
        self.folder = folder
        self.defaults = defaults
        self.accountPicture = accountPicture
        displayName = defaults.string(forKey: Self.nameKey) ?? ""
        photo = Self.storedPhoto(in: folder) ?? accountPicture()
    }

    func setPhoto(from url: URL) throws {
        let data = try ScaledImage.jpeg(from: url, longestSide: 256)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: avatarURL, options: .atomic)
        photo = NSImage(data: data)
    }

    func resetPhoto() {
        if FileManager.default.fileExists(atPath: avatarURL.path(percentEncoded: false)) {
            do {
                try FileManager.default.removeItem(at: avatarURL)
            } catch {
                return
            }
        }
        photo = accountPicture()
    }

    private var avatarURL: URL {
        folder.appending(path: "avatar.jpg", directoryHint: .notDirectory)
    }

    private static func storedPhoto(in folder: URL) -> NSImage? {
        NSImage(contentsOf: folder.appending(path: "avatar.jpg", directoryHint: .notDirectory))
    }

    private static let nameKey = "profile.name"
}
