import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// JPEG, HEIC, TIFF and PNG go through the same pipeline as RAW files: a photo library is
/// not made of RAW files only. The files are generated here, so this suite runs anywhere.
@Suite struct RenderedFormatsTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-formats-\(UUID().uuidString)")
    let probe = PixelProbe()

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ format: ExportOptions.Format, size: CGSize = CGSize(width: 400, height: 300)) throws -> URL {
        var options = ExportOptions()
        options.format = format
        let url = folder.appendingPathComponent("picture.\(format.fileExtension)")
        try Renderer().write(PixelProbe.swatch(r: 0.2, g: 0.18, b: 0.15, size: size), to: url, options: options)
        return url
    }

    @Test(arguments: ExportOptions.Format.allCases)
    func opensEveryRenderedFormat(format: ExportOptions.Format) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try RawSource(url: try file(format))
        #expect(source.info.imageSize == CGSize(width: 400, height: 300))
        #expect(try source.image().extent.size == CGSize(width: 400, height: 300))
        #expect(!source.info.isRaw)
    }

    @Test func theSamePipelineApplies() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try RawSource(url: try file(.jpeg))
        let neutral = try probe.average(of: source.image())
        #expect(abs(neutral.luminance - 0.18) < 0.02)

        var brighter = Adjustments()
        brighter.exposure = 1
        #expect(abs(try probe.average(of: source.image(adjustments: brighter)).luminance - neutral.luminance * 2) < 0.03)

        var mono = Adjustments()
        mono.saturation = -100
        #expect(try probe.average(of: source.image(adjustments: mono)).chroma < 0.01)
    }

    @Test func whiteBalanceIsRelativeToThePictureAsItIs() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try RawSource(url: try file(.jpeg))
        let asShot = source.info.asShotWhiteBalance
        var warm = Adjustments()
        warm.whiteBalance = WhiteBalance(temperature: asShot.temperature + 2500, tint: asShot.tint)
        let (neutral, warmed) = (try probe.average(of: source.image()), try probe.average(of: source.image(adjustments: warm)))
        #expect(warmed.r / warmed.b > neutral.r / neutral.b)
    }

    @Test func previewsAreDecodedSmaller() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try RawSource(url: try file(.jpeg, size: CGSize(width: 1600, height: 1200)))
        let preview = try source.image(scaleFactor: 0.25)
        #expect(abs(preview.extent.width - 400) <= 1 && abs(preview.extent.height - 300) <= 1)
    }

    /// What a RAW decoder offers and a rendered file cannot: the interface hides it.
    @Test func decoderOnlyToolsAreReportedAsUnavailable() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try RawSource(url: try file(.jpeg))
        #expect(!source.info.capabilities.sharpness && !source.info.capabilities.luminanceNoiseReduction)
        #expect(source.whiteBalance(neutralAt: NormalizedPoint(x: 0.5, y: 0.5)) == nil)
    }

    @Test func aFileThatIsNotAPictureIsStillRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.jpg")
        try Data("not a picture".utf8).write(to: url)
        #expect(throws: RawEngineError.unsupportedFile(url)) { try RawSource(url: url) }
    }
}
