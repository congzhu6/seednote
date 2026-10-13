import ImageIO
import UIKit

/// Decodes saved images at the size they are drawn and keeps the result. Views call this
/// from `body`, which runs on every redraw; decoding a full 2400-pixel JPEG each time is
/// what made lists and the editor slow. Attachment files are immutable once named, so
/// the path plus target size is a stable cache key.
enum StoredImage {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// An image that covers `points` at `scale`, as used with `scaledToFill`.
    static func thumbnail(_ url: URL?, filling points: CGSize, scale: CGFloat = 3) -> UIImage? {
        guard let url else { return nil }
        let key = "\(url.path)#\(Int(points.width))x\(Int(points.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let longEdge = CGFloat(max(width, height))
        let coverage = max(points.width * scale / CGFloat(width), points.height * scale / CGFloat(height))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, (longEdge * coverage).rounded(.up))
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let result = UIImage(cgImage: image, scale: scale, orientation: .up)
        cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
}
