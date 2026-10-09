// Draws three overlapping, rounded embers on a navy tile. The 1024 px canvas
// leaves 100 px around the tile for the system icon mask.
//
//   swift scripts/make-icon.swift Assets/AppIcon-1024.png
//   icon_dir=$(mktemp -d)
//   mkdir -p "$icon_dir/AppIcon.iconset"
//   for s in 16 32 128 256 512; do
//     sips -z $s $s Assets/AppIcon-1024.png --out "$icon_dir/AppIcon.iconset/icon_${s}x${s}.png"
//     sips -z $((s*2)) $((s*2)) Assets/AppIcon-1024.png --out "$icon_dir/AppIcon.iconset/icon_${s}x${s}@2x.png"
//   done
//   iconutil -c icns "$icon_dir/AppIcon.iconset" -o Assets/AppIcon.icns || \
//     swift scripts/make-icon.swift --pack-iconset "$icon_dir/AppIcon.iconset" Assets/AppIcon.icns
//   rm -r "$icon_dir"
import AppKit

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--pack-iconset" {
    let iconset = URL(fileURLWithPath: CommandLine.arguments[2])
    let chunks: [(String, String)] = [
        ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png")
    ]
    var icns = Data("icns".utf8)
    icns.append(contentsOf: [0, 0, 0, 0])
    for (type, filename) in chunks {
        let png = try Data(contentsOf: iconset.appending(path: filename))
        icns.append(contentsOf: type.utf8)
        var length = UInt32(png.count + 8).bigEndian
        withUnsafeBytes(of: &length) { icns.append(contentsOf: $0) }
        icns.append(png)
    }
    var length = UInt32(icns.count).bigEndian
    withUnsafeBytes(of: &length) { icns.replaceSubrange(4..<8, with: $0) }
    try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    exit(0)
}

let canvas: CGFloat = 1024
let body: CGFloat = 824
let origin = (canvas - body) / 2

let tileColor = CGColor(srgbRed: 32 / 255, green: 53 / 255, blue: 67 / 255, alpha: 1)
let backEmberColor = CGColor(srgbRed: 215 / 255, green: 103 / 255, blue: 68 / 255, alpha: 1)
let frontEmberColor = CGColor(srgbRed: 240 / 255, green: 139 / 255, blue: 82 / 255, alpha: 1)

func roundedDiamond(center: CGPoint, radius: CGFloat, corner: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let x = center.x
    let y = center.y
    path.move(to: CGPoint(x: x - corner, y: y + radius - corner))
    path.addQuadCurve(to: CGPoint(x: x + corner, y: y + radius - corner), control: CGPoint(x: x, y: y + radius))
    path.addLine(to: CGPoint(x: x + radius - corner, y: y + corner))
    path.addQuadCurve(to: CGPoint(x: x + radius - corner, y: y - corner), control: CGPoint(x: x + radius, y: y))
    path.addLine(to: CGPoint(x: x + corner, y: y - radius + corner))
    path.addQuadCurve(to: CGPoint(x: x - corner, y: y - radius + corner), control: CGPoint(x: x, y: y - radius))
    path.addLine(to: CGPoint(x: x - radius + corner, y: y - corner))
    path.addQuadCurve(to: CGPoint(x: x - radius + corner, y: y + corner), control: CGPoint(x: x - radius, y: y))
    path.closeSubpath()
    return path
}

let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
    let context = NSGraphicsContext.current!.cgContext
    let tile = CGRect(x: origin, y: origin, width: body, height: body)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.setFillColor(tileColor)
    context.fillPath()

    context.setFillColor(backEmberColor)
    context.addPath(roundedDiamond(center: CGPoint(x: 340, y: 419), radius: 145, corner: 41))
    context.addPath(roundedDiamond(center: CGPoint(x: 684, y: 419), radius: 145, corner: 41))
    context.fillPath()

    context.setFillColor(frontEmberColor)
    context.addPath(roundedDiamond(center: CGPoint(x: 512, y: 485), radius: 240, corner: 68))
    context.fillPath()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
