import AppKit
import Foundation
import Testing
@testable import Desk

@MainActor
@Test func profileNameAndPhotoRoundTripThroughAnInjectedAccountPicture() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "desk-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appending(path: "support", directoryHint: .isDirectory)
    let suite = "desk-profile-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let picture = NSImage(size: NSSize(width: 8, height: 8))
    let model = DeskModel(
        store: ThreadStore(directory: root.appending(path: "threads")),
        runner: EchoAgentRunner(),
        trash: { _ in },
        defaults: defaults,
        supportDirectory: support,
        accountPicture: { picture }
    )
    #expect(model.profile.displayName.isEmpty)
    #expect(model.profile.photo === picture)

    model.profile.displayName = "Ada"
    let source = root.appending(path: "wide.png")
    try writePNG(width: 400, height: 200, to: source)
    try model.profile.setPhoto(from: source)

    let avatar = support.appending(path: "avatar.jpg")
    let jpeg = try Data(contentsOf: avatar)
    #expect(jpeg.starts(with: [0xFF, 0xD8]))
    let rep = try #require(NSBitmapImageRep(data: jpeg))
    #expect(rep.pixelsWide == 256)
    #expect(rep.pixelsHigh == 128)
    #expect(model.profile.photo !== picture)

    let relaunched = DeskModel(
        store: ThreadStore(directory: root.appending(path: "threads")),
        runner: EchoAgentRunner(),
        trash: { _ in },
        defaults: defaults,
        supportDirectory: support,
        accountPicture: { picture }
    )
    #expect(relaunched.profile.displayName == "Ada")
    #expect(relaunched.profile.photo != nil)
    #expect(relaunched.profile.photo !== picture)

    relaunched.profile.resetPhoto()
    #expect(!FileManager.default.fileExists(atPath: avatar.path(percentEncoded: false)))
    #expect(relaunched.profile.photo === picture)

    let junk = root.appending(path: "notes.txt")
    try Data("nope".utf8).write(to: junk)
    #expect(throws: DeskImageError.self) {
        try relaunched.profile.setPhoto(from: junk)
    }
    #expect(relaunched.profile.photo === picture)
}
