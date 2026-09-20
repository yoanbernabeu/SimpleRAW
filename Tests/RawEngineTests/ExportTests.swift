import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Testing
import TestSupport
@testable import RawEngine

@Suite struct ExportFormatTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-export-\(UUID().uuidString)")
    let renderer = Renderer()
    let picture = PixelProbe.swatch(r: 0.5, g: 0.3, b: 0.1, size: CGSize(width: 400, height: 300))

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func properties(of url: URL) throws -> [String: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    @Test(arguments: [
        (ExportOptions.Format.jpeg, "jpg", 8), (.tiff16, "tif", 16), (.png, "png", 8), (.heic, "heic", 8),
    ])
    func writesEveryFormatAtItsBitDepth(format: ExportOptions.Format, fileExtension: String, depth: Int) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = ExportOptions()
        options.format = format
        #expect(format.fileExtension == fileExtension)
        let destination = folder.appendingPathComponent("out.\(fileExtension)")
        try renderer.write(picture, to: destination, options: options)

        let written = try properties(of: destination)
        #expect(written[kCGImagePropertyDepth as String] as? Int == depth)
        #expect(written[kCGImagePropertyPixelWidth as String] as? Int == 400)
    }

    /// A print file must keep what 8 bits would crush: a TIFF is written without clipping to
    /// the display range, in 16 bits.
    @Test func aPresetNamesItsFilesAfterItsFormat() {
        var preset = ExportPreset(name: "Print")
        preset.options.format = .tiff16
        #expect(preset.fileName(for: URL(fileURLWithPath: "/p/R0001.DNG")) == "R0001.tif")
    }

    @Test func copyrightAndAuthorAreWrittenInTheFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = ExportOptions()
        options.copyright = "© 2026 Yoan"
        options.author = "Yoan"
        let destination = folder.appendingPathComponent("signed.jpg")
        try renderer.write(picture, to: destination, options: options)

        let written = try properties(of: destination)
        let iptc = try #require(written[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        #expect(iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String == "© 2026 Yoan")
        let tiff = try #require(written[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFArtist as String] as? String == "Yoan")
    }

    @Test func outputSharpeningCrispsTheResizedPicture() throws {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 780, y: 0)
        gradient.point1 = CGPoint(x: 820, y: 0)
        gradient.color0 = CIColor(red: 0.2, green: 0.2, blue: 0.2)
        gradient.color1 = CIColor(red: 0.7, green: 0.7, blue: 0.7)
        let edge = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 800))

        var plain = ExportOptions()
        plain.longEdge = 400
        var sharpened = plain
        sharpened.sharpening = .high
        let probe = PixelProbe()
        func contrast(_ options: ExportOptions) throws -> Float {
            let output = Renderer.prepared(edge, options: options)
            let dark = try probe.average(of: output, in: CGRect(x: 190, y: 80, width: 3, height: 40)).luminance
            let light = try probe.average(of: output, in: CGRect(x: 207, y: 80, width: 3, height: 40)).luminance
            return light - dark
        }
        #expect(try contrast(sharpened) > contrast(plain))
    }
}

@Suite struct UniqueDestinationTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-unique-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// An export never writes over a file that is already there.
    @Test func aTakenNameGetsANumber() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let wanted = folder.appendingPathComponent("R0001-web.jpg")
        #expect(ExportPreset.freeDestination(wanted) == wanted)
        try Data("first".utf8).write(to: wanted)
        let second = ExportPreset.freeDestination(wanted)
        #expect(second.lastPathComponent == "R0001-web-2.jpg")
        try Data("second".utf8).write(to: second)
        #expect(ExportPreset.freeDestination(wanted).lastPathComponent == "R0001-web-3.jpg")
    }
}
