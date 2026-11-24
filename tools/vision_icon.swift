// Renders the layers of the shared app's visionOS icon from the artwork of frontend-ios/AppIcon.icon (an Icon Composer
// document, which Xcode builds for iOS only: on visionOS the app had no icon). visionOS wants an image stack of three
// 1024 x 1024 layers that it shows in a circle with depth between them:
//   Back    the dark background with the warm glow, opaque
//   Middle  the bar under the letters
//   Front   the letters
// The colours, the gradient and the two offsets are those of icon.json. Run it again when the artwork changes:
//   swift tools/vision_icon.swift frontend-ios/AppIcon.icon frontend-ios/AppIcon.solidimagestack
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: vision_icon.swift <AppIcon.icon> <AppIcon.solidimagestack>") }
let assets = URL(fileURLWithPath: arguments[1]).appendingPathComponent("Assets"), out = URL(fileURLWithPath: arguments[2])
let side = 1024

func layer(_ draw: (CGContext, CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    draw(context.cgContext, CGRect(x: 0, y: 0, width: side, height: side))
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

func svg(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: assets.appendingPathComponent(name)) else { fatalError("cannot read \(name)") }
    return image
}

/// The shape of an SVG filled with a top-to-bottom gradient, moved down by `down` pixels.
func shape(_ name: String, top: NSColor, bottom: NSColor, down: CGFloat) -> Data {
    layer { context, rect in
        svg(name).draw(in: rect.offsetBy(dx: 0, dy: -down))
        context.setBlendMode(.sourceIn)
        NSGradient(starting: bottom, ending: top)!.draw(in: rect, angle: 90)
    }
}

let back = layer { _, rect in
    NSGradient(starting: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1))!.draw(in: rect, angle: 90)
    svg("glow-soft.svg").draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.75)
}
let middle = shape("bar.svg", top: NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 0.9), bottom: NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 0.9), down: 14)
let front = shape("nx.svg", top: NSColor(srgbRed: 1, green: 0.94, blue: 0.84, alpha: 1), bottom: NSColor(srgbRed: 1, green: 0.80, blue: 0.56, alpha: 1), down: -8)

let info = #"{"author":"xcode","version":1}"#
func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
}
try? FileManager.default.removeItem(at: out)
try write(#"{"info":\#(info),"layers":[{"filename":"Front.solidimagestacklayer"},{"filename":"Middle.solidimagestacklayer"},{"filename":"Back.solidimagestacklayer"}]}"#,
          out.appendingPathComponent("Contents.json"))
for (name, data) in [("Front", front), ("Middle", middle), ("Back", back)] {
    let folder = out.appendingPathComponent(name + ".solidimagestacklayer")
    try write(#"{"info":\#(info)}"#, folder.appendingPathComponent("Contents.json"))
    try write(#"{"images":[{"filename":"\#(name).png","idiom":"vision","scale":"2x"}],"info":\#(info)}"#, folder.appendingPathComponent("Content.imageset/Contents.json"))
    try data.write(to: folder.appendingPathComponent("Content.imageset/\(name).png"))
}
print("wrote \(out.path)")
