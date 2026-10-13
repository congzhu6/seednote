import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageService {
    private static let maximumBytes = 20 * 1024 * 1024
    private static let maximumPixels = 40_000_000
    private static let maximumEdge = 2_400

    private enum ImageError: LocalizedError {
        case tooLarge, tooManyPixels, invalidImage, encodeFailed

        var errorDescription: String? {
            switch self {
            case .tooLarge: return L("This image exceeds 20 MB. Choose a smaller image.", "图片超过 20 MB，请选择较小的图片。")
            case .tooManyPixels: return L("This image exceeds 40 megapixels. Choose a smaller image.", "图片超过 4000 万像素，请选择较小的图片。")
            case .invalidImage: return L("This image could not be read.", "无法读取这张图片。")
            case .encodeFailed: return L("This image could not be prepared.", "无法处理这张图片。")
            }
        }
    }

    static func prepare(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw ImageError.invalidImage }
        guard data.count <= maximumBytes else { throw ImageError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageError.invalidImage }
        // Division avoids overflowing Int on malicious metadata.
        guard width <= maximumPixels / height else { throw ImageError.tooManyPixels }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= maximumEdge, image.height <= maximumEdge else {
            throw ImageError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encodeFailed }
        return output as Data
    }

    static func recognize(_ data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let prepared = try prepare(data)
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(data: prepared, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
