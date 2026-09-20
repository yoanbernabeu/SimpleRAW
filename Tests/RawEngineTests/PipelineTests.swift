import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// End-to-end tests on a real DNG. Samples are not versioned: the suite is skipped
/// as long as `Samples/` holds no file.
/// These assert values measured on the reference photograph — its size, its exposure against
/// the camera's own JPEG — so they ask for that one and not for whatever sorts first.
@Suite(.enabled(if: Sample.reference != nil, "No \(Sample.referenceName) in Samples/"))
struct PipelineTests {
    let source: RawSource
    let probe = PixelProbe()

    init() throws {
        source = try RawSource(url: try #require(Sample.reference))
    }

    @Test func readsCameraMetadata() {
        #expect(source.info.model?.isEmpty == false)
        #expect(source.info.nativeSize.width > 0)
        #expect(source.info.asShotWhiteBalance.temperature > 1000)
    }

    @Test func exposureBrightensTheImage() throws {
        var brighter = Adjustments()
        brighter.exposure = 1
        #expect(try luminance(brighter) > luminance(Adjustments()) * 1.2)
    }

    @Test func shadowsLiftTheImage() throws {
        var lifted = Adjustments()
        lifted.shadows = 100
        #expect(try luminance(lifted) > luminance(Adjustments()))
    }

    @Test func negativeSaturationRemovesColor() throws {
        var mono = Adjustments()
        mono.saturation = -100
        #expect(try average(mono).chroma < 0.01)
    }

    @Test func warmerWhiteBalanceShiftsTowardRed() throws {
        let asShot = source.info.asShotWhiteBalance
        var warm = Adjustments()
        warm.whiteBalance = WhiteBalance(temperature: asShot.temperature + 3000, tint: asShot.tint)
        let neutral = try average(Adjustments())
        let warmed = try average(warm)
        #expect(warmed.r / warmed.b > neutral.r / neutral.b)
    }

    @Test func resettingAdjustmentsRestoresTheNeutralRender() throws {
        let before = try average(Adjustments())
        var heavy = Adjustments()
        heavy.exposure = 2
        heavy.sharpness = 100
        heavy.whiteBalance = WhiteBalance(temperature: 9000, tint: 30)
        _ = try average(heavy)
        let after = try average(Adjustments())
        #expect(abs(before.r - after.r) < 0.001)
        #expect(abs(before.b - after.b) < 0.001)
    }

    @Test func exportsAResizedJPEG() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleraw-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        var options = ExportOptions()
        options.longEdge = 1024
        try Renderer().writeJPEG(source.image(scaleFactor: 0.25), to: destination, options: options)

        let exported = try #require(CIImage(contentsOf: destination))
        #expect(max(exported.extent.width, exported.extent.height) == 1024)
    }

    /// The camera JPEG is a look, not ground truth, but a neutral render straying more than
    /// 0.75 EV from it means the decoder misread the exposure. Regression: shots taken with
    /// the camera's highlight correction record a +1 EV `BaselineExposure`, which
    /// `CIRAWFilter` ignores, and used to come out a full stop too dark.
    @Test(arguments: Sample.all)
    func neutralRenderMatchesCameraExposure(url: URL) throws {
        let source = try RawSource(url: url)
        let rendered = try probe.average(of: source.image(scaleFactor: 0.125)).luminance
        let camera = try probe.average(of: source.embeddedPreview()).luminance
        #expect(abs(log2(rendered / camera)) < 0.75)
    }

    /// "Camera match" was fitted on Ricoh GR III files; it must keep earning its name.
    @Test func cameraMatchBringsTheRenderCloserToTheCamera() throws {
        let preset = try #require(Preset.builtIns.first { $0.name == "Camera match" })
        var matched = Adjustments()
        preset.apply(to: &matched)

        var (neutralGap, matchedGap): (Float, Float) = (0, 0)
        for url in Sample.all {
            let source = try RawSource(url: url)
            let camera = try probe.average(of: source.embeddedPreview()).luminance
            neutralGap += abs(log2(try probe.average(of: source.image(scaleFactor: 0.125)).luminance / camera))
            matchedGap += abs(log2(try probe.average(of: source.image(adjustments: matched, scaleFactor: 0.125)).luminance / camera))
        }
        #expect(matchedGap < neutralGap / 2)
    }

    @Test(arguments: Sample.all)
    func embeddedPreviewIsUpright(url: URL) throws {
        let source = try RawSource(url: url)
        let rendered = try source.image(scaleFactor: 0.125).extent
        let preview = try source.embeddedPreview().extent
        #expect((rendered.width > rendered.height) == (preview.width > preview.height))
    }

    @Test(arguments: Sample.all)
    func imageSizeIsTheUprightSize(url: URL) throws {
        let source = try RawSource(url: url)
        #expect(try source.image().extent.size == source.info.imageSize)
    }

    /// Sliders for optional settings start from what the decoder picked, on the user scale.
    @Test func decoderDefaultsAreOnTheSliderScale() {
        let defaults = source.info.decoderDefaults
        for value in [defaults.sharpness, defaults.luminanceNoiseReduction, defaults.colorNoiseReduction] {
            #expect((0...100).contains(value))
        }
    }

    @Test func spellingOutDecoderDefaultsChangesNothing() throws {
        var explicit = Adjustments()
        explicit.sharpness = source.info.decoderDefaults.sharpness
        explicit.luminanceNoiseReduction = source.info.decoderDefaults.luminanceNoiseReduction
        explicit.colorNoiseReduction = source.info.decoderDefaults.colorNoiseReduction
        let implicit = try average(Adjustments())
        let spelledOut = try average(explicit)
        #expect(abs(implicit.luminance - spelledOut.luminance) < 0.0005)
    }

    // MARK: - Measurements

    /// A reduced-size decode is enough for an average, and keeps the suite fast.
    private func average(_ adjustments: Adjustments) throws -> PixelProbe.Pixel {
        try probe.average(of: source.image(adjustments: adjustments, scaleFactor: 0.125))
    }

    private func luminance(_ adjustments: Adjustments) throws -> Float {
        try average(adjustments).luminance
    }
}
