import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photos for tests of what happens *around* a picture: undo, layers, saving, stepping through
/// the grid, importing. None of that needs a RAW file.
///
/// The DNGs of `Samples/` when there are some, so that the real thing is exercised; generated
/// TIFFs otherwise, so that a fresh clone skips none of these tests. What only a RAW file can
/// show (as-shot white balance, the decoder's own sliders) stays on `Sample`.
public enum TestPhoto {
    public static let all: [URL] = Sample.all.count >= 2 ? Sample.all : generated

    /// The one a test opens when it just needs a photograph. The reference file when it is
    /// there, so that a photograph dropped into `Samples/` cannot change what these tests
    /// are looking at — `all` is sorted by name, and a new file may well sort first.
    public static var url: URL { all.first { $0.lastPathComponent == Sample.referenceName } ?? all[0] }

    /// Two different pictures: the importer tells duplicates by content.
    private static let generated: [URL] = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleraw-test-photos-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return [("street.tiff", 0.2), ("harbour.tiff", 0.6)].compactMap { name, warmth in
            let url = folder.appendingPathComponent(name)
            return write(gradient(warmth: warmth), to: url) ? url : nil
        }
    }()

    /// A landscape picture with a range of tones, like a photo: a flat color would hide what
    /// light and color sliders do.
    private static func gradient(warmth: Double) -> CGImage? {
        // Larger than any view the tests fit it in: a preview is a reduction, as with a real photo.
        let width = 2400, height = 1600
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let gradient = CGGradient(
            colorsSpace: nil,
            colors: [
                CGColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1),
                CGColor(red: 0.5 + warmth * 0.3, green: 0.5, blue: 0.5 - warmth * 0.3, alpha: 1),
                CGColor(red: 0.95, green: 0.93, blue: 0.9, alpha: 1),
            ] as CFArray,
            locations: nil
        ) else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return context.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) -> Bool {
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            return false
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "SimpleRAW", kCGImagePropertyTIFFModel: "Test Camera",
                kCGImagePropertyTIFFCompression: 5,
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
