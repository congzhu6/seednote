import AppKit
// Usage: swift Tools/generate_icons.swift Resources/Assets.xcassets/AppIcon.appiconset
// Writes the single 1024-pixel App Store icon; Xcode derives every device size from it.
let pixels = 1024
// App Store Connect rejects an app icon with an alpha channel, so draw into an opaque
// bitmap directly. This also avoids NSImage.lockFocus, which renders black without a window server.
let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(red: 244/255, green: 244/255, blue: 241/255, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Georgia", size: 800)!, .foregroundColor: NSColor(red: 37/255, green: 38/255, blue: 37/255, alpha: 1)]
let mark = "s" as NSString
let size = mark.size(withAttributes: attributes)
mark.draw(at: NSPoint(x: (1024 - size.width)/2 - 12, y: (1024-size.height)/2 + 45), withAttributes: attributes)
NSColor(red: 198/255, green: 64/255, blue: 49/255, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 689, y: 249, width: 49, height: 49)).fill()
NSGraphicsContext.current = nil
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
try png.write(to: directory.appendingPathComponent("AppIcon.png"))
