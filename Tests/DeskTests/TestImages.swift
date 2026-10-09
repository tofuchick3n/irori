import AppKit
import Foundation
@testable import Desk

@MainActor
func writePNG(width: Int, height: Int, to url: URL) throws {
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
    ), let pixels = rep.bitmapData else {
        throw DeskImageError.unreadable
    }
    rep.size = NSSize(width: width, height: height)
    let count = width * height
    for index in 0..<count {
        pixels[index * 4] = 220
        pixels[index * 4 + 1] = 40
        pixels[index * 4 + 2] = 40
        pixels[index * 4 + 3] = 255
    }
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw DeskImageError.unreadable
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
}
