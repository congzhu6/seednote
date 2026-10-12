import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(red: 244/255, green: 244/255, blue: 241/255, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Georgia", size: 800)!, .foregroundColor: NSColor(red: 37/255, green: 38/255, blue: 37/255, alpha: 1)]
let mark = "s" as NSString
let size = mark.size(withAttributes: attributes)
mark.draw(at: NSPoint(x: (1024 - size.width)/2 - 12, y: (1024-size.height)/2 + 45), withAttributes: attributes)
NSColor(red: 198/255, green: 64/255, blue: 49/255, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 689, y: 249, width: 49, height: 49)).fill()
image.unlockFocus()
let directory = URL(fileURLWithPath: output, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (points, scale) in [(60,2),(60,3),(40,2),(40,3),(29,2),(29,3),(20,2),(20,3)] {
    let pixels = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("Icon\(points)@\(scale)x.png"))
}
