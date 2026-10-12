import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Seednote

final class ImageServiceTests: XCTestCase {
    private func image(width: Int, height: Int, text: String? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let text {
                (text as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                    .foregroundColor: UIColor.black
                ])
            }
        }
    }

    func testLargeSelectedImageIsNormalizedToBoundedJPEG() throws {
        let input = try XCTUnwrap(image(width: 3200, height: 800).pngData())
        let output = try ImageService.prepare(input)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 2400)
        XCTAssertEqual(decoded.height, 600)
    }

    func testEXIFOrientationIsAppliedToStoredImage() throws {
        let pixels = try XCTUnwrap(image(width: 640, height: 320).cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared = try ImageService.prepare(data as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared as CFData, nil))
        let rotated = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(rotated.width, 320)
        XCTAssertEqual(rotated.height, 640)
    }

    func testInvalidAndOversizedImportsAreRejected() {
        XCTAssertThrowsError(try ImageService.prepare(Data()))
        XCTAssertThrowsError(try ImageService.prepare(Data("not an image".utf8)))
        XCTAssertThrowsError(try ImageService.prepare(Data(repeating: 0, count: 20 * 1024 * 1024 + 1)))
    }

    func testImageAboveFortyMegapixelsIsRejectedBeforeNormalization() throws {
        let pixels = Data(repeating: 255, count: 8001 * 5000)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 8001, height: 5000, bitsPerComponent: 8,
                                         bitsPerPixel: 8, bytesPerRow: 8001,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                         provider: provider, decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertLessThan(encoded.length, 20 * 1024 * 1024)
        XCTAssertThrowsError(try ImageService.prepare(encoded as Data))
    }

    func testVisionRecognizesActualPixelsWithoutInventedResult() async throws {
        let fixture = try XCTUnwrap(image(width: 1200, height: 300, text: "SEEDNOTE SOURCE").pngData())
        let text = try await ImageService.recognize(fixture)
        XCTAssertTrue(text.uppercased().contains("SEEDNOTE SOURCE"), "Actual Vision output: \(text)")
    }
}
