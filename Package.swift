// swift-tools-version: 6.2

import Foundation
import PackageDescription

/// `scripts/fetch-whistle` puts the prebuilt Needle engine here.
let whistle = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: ".build/whistle").path

let package = Package(
    name: "Desk",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Desk",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "Needle",
            ],
            linkerSettings: [.unsafeFlags(["-L", whistle])]
        ),
        .systemLibrary(name: "Needle", path: "Vendor/Needle"),
        .testTarget(
            name: "DeskTests",
            dependencies: ["Desk"],
            resources: [
                .copy("Fixtures/claude-stream.jsonl"),
                .copy("Fixtures/codex-stream.jsonl"),
                .copy("Fixtures/grok-stream.jsonl"),
                .copy("Fixtures/muse-stream.jsonl"),
                .copy("Fixtures/muse-tools-stream.jsonl"),
                .copy("Fixtures/claude-approval-stream.jsonl"),
                .copy("Fixtures/codex-approval-stream.jsonl"),
            ]
        ),
    ]
)
