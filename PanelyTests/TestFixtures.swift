import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

enum Fixture {
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writeFile(_ url: URL, bytes: [UInt8] = [0]) throws -> URL {
        try Data(bytes).write(to: url)
        return url
    }

    static func zipDirectory(_ sourceDir: URL, to zipURL: URL) throws {
        try FileManager.default.zipItem(at: sourceDir, to: zipURL, shouldKeepParent: false)
    }

    /// Generates a real PNG with the given pixel dimensions. Used by tests
    /// that need an image whose header reports a known size (e.g.,
    /// `ImageLoader.dimensions`).
    static func makePNG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImg = ctx.makeImage() else {
            throw NSError(domain: "Fixture", code: 1, userInfo: nil)
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "Fixture", code: 2, userInfo: nil)
        }
        CGImageDestinationAddImage(dest, cgImg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Fixture", code: 3, userInfo: nil)
        }
        return mutableData as Data
    }
}
