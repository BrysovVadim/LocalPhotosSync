import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import LocalPhotosSyncUSB

final class PhoneThumbnailDecoderTests: XCTestCase {
    func testDecodesPrivateImageWithinCache() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try writeImage(width: 640, height: 320, in: directory)

        let result = try XCTUnwrap(PhoneThumbnailDecoder.decode(image, within: directory))

        XCTAssertEqual(result.image.width, 512)
        XCTAssertEqual(result.image.height, 256)
    }

    func testTruncatedImageIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("broken.img")
        try Data([0xff, 0xd8, 0xff, 0xe0, 0x00]).write(to: image)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)

        XCTAssertNil(PhoneThumbnailDecoder.decode(image, within: directory))
    }

    func testSymlinkToImageOutsideCacheIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let image = try writeImage(width: 2, height: 2, in: directory)
        let link = cache.appendingPathComponent("linked.img")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)

        XCTAssertNil(PhoneThumbnailDecoder.decode(link, within: cache))
    }

    func testExcessiveImageDimensionsAreRejectedBeforeDecode() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try writeImage(width: 5000, height: 1, in: directory)

        XCTAssertNil(PhoneThumbnailDecoder.decode(image, within: directory))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func writeImage(width: Int, height: Int, in directory: URL) throws -> URL {
        let pixels = Data(repeating: 0xff, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = directory.appendingPathComponent("thumbnail.img")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
