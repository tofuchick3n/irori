import AppKit
import Foundation
import Testing
@testable import Desk

/// Sends a solid red image to each agent that takes images natively and asks for its color.
/// Opt in with `DESK_LIVE=1 swift test --disable-sandbox --filter LiveAttachment`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESK_LIVE"] == "1"))
struct LiveAttachmentTests {
    @Test(arguments: [AgentID.claude, .codex, .muse])
    func seesAnAttachedImage(_ agent: AgentID) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "desk-live-image-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(path: "swatch.png")
        try redSquare().write(to: image)

        var permissions = AgentPermissions(allowsFileWrites: false, allowedCommands: [])
        permissions.images = [image]
        let stream = RoutingAgentRunner().run(
            agent: agent,
            prompt: "User: What single color fills the attached image? Answer with one word, and don't open any files.",
            session: nil,
            workspace: folder,
            model: nil,
            effort: nil,
            permissions: permissions,
            executable: nil,
            approve: { _ in .deny }
        )
        var text = ""
        for try await event in stream {
            if case .text(let chunk) = event { text += chunk }
        }
        print("\(agent.displayName) saw: \(text)")
        #expect(text.lowercased().contains("red"))
    }

    private func redSquare() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
