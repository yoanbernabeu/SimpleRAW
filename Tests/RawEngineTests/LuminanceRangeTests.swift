import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// A mask limited to some tones: "a graduated filter on the sky that spares the steeple".
@Suite struct LuminanceRangeMathTests {
    @Test func theWholeRangeLetsEverythingThrough() {
        let range = LuminanceRange()
        #expect(range.isWhole)
        for level in [0.0, 0.01, 0.5, 0.99, 1.0] { #expect(range.value(at: level) == 1) }
    }

    @Test func tonesInsideAreFullTonesOutsideAreOut() {
        let highlights = LuminanceRange(lower: 0.6, upper: 1, softness: 0.1)
        #expect(highlights.value(at: 0.9) == 1 && highlights.value(at: 1) == 1)
        #expect(highlights.value(at: 0.3) == 0 && highlights.value(at: 0) == 0)
        let midtones = LuminanceRange(lower: 0.3, upper: 0.7, softness: 0.1)
        #expect(midtones.value(at: 0.5) == 1 && midtones.value(at: 0.05) == 0 && midtones.value(at: 0.95) == 0)
    }

    /// The fade is centered on each bound and smooth: no edge drawn around the steeple.
    @Test func theEdgesFadeSmoothlyAroundTheBounds() {
        let range = LuminanceRange(lower: 0.5, upper: 1, softness: 0.2)
        #expect(abs(range.value(at: 0.5) - 0.5) < 1e-9)
        #expect(range.value(at: 0.4) == 0 && range.value(at: 0.6) == 1)
        let samples = stride(from: 0.4, through: 0.6, by: 0.01).map(range.value(at:))
        for (previous, next) in zip(samples, samples.dropFirst()) {
            #expect(next >= previous && next - previous < 0.09)
        }
        // A hard range is allowed, and is hard.
        let hard = LuminanceRange(lower: 0.5, upper: 1, softness: 0)
        #expect(hard.value(at: 0.499) == 0 && hard.value(at: 0.501) == 1)
    }

    @Test func isPartOfTheDocumentAndBounded() throws {
        let layer = #"{"id": "7E57AB1E-0000-4000-8000-0000000000D1", "mask": {"brush": {"strokes": []}}, "luminanceRange": {"lower": 0.6}}"#
        let decoded = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"locals": [\#(layer)]}"#.utf8))
        #expect(decoded.locals[0].luminanceRange == LuminanceRange(lower: 0.6, upper: 1, softness: LuminanceRange().softness))
        #expect(try JSONDecoder().decode(Adjustments.self, from: decoded.jsonData()) == decoded)

        let hostile = #"{"id": "7E57AB1E-0000-4000-8000-0000000000D2", "mask": {"brush": {"strokes": []}}, "luminanceRange": {"lower": 1e308, "upper": 0.5, "softness": 1e308}}"#
        let range = try #require(try JSONDecoder().decode(Adjustments.self, from: Data(#"{"locals": [\#(hostile)]}"#.utf8)).locals[0].luminanceRange)
        #expect((0...1).contains(range.lower) && (0...1).contains(range.upper) && range.lower <= range.upper && (0...1).contains(range.softness))
        #expect(range == LuminanceRange(lower: 0.5, upper: 1, softness: 1))
        // Bounds that come down to the whole scale once sanitized are no range at all.
        let whole = #"{"id": "7E57AB1E-0000-4000-8000-0000000000D4", "mask": {"brush": {"strokes": []}}, "luminanceRange": {"lower": 1e308, "upper": -1e308}}"#
        #expect(try JSONDecoder().decode(Adjustments.self, from: Data(#"{"locals": [\#(whole)]}"#.utf8)).locals[0].luminanceRange == nil)
        // Layers saved before it existed, and a whole range, which is no range at all.
        let plain = #"{"id": "7E57AB1E-0000-4000-8000-0000000000D3", "mask": {"brush": {"strokes": []}}}"#
        #expect(try JSONDecoder().decode(LocalAdjustment.self, from: Data(plain.utf8)).luminanceRange == nil)
        var layerInMemory = LocalAdjustment(mask: .brush(BrushMask()))
        layerInMemory.luminanceRange = LuminanceRange()
        #expect(layerInMemory.luminanceRange == nil)
    }
}

@Suite struct LuminanceRangeStageTests {
    let probe = PixelProbe()
    let stage = LocalAdjustmentsStage()

    /// A sky (sRGB 0.8) with a steeple (sRGB 0.2) standing in it, under a mask covering both.
    private var steepleInTheSky: CIImage {
        PixelProbe.swatch(r: 0.033, g: 0.033, b: 0.033, size: CGSize(width: 60, height: 200))
            .transformed(by: CGAffineTransform(translationX: 120, y: 0))
            .composited(over: PixelProbe.swatch(r: 0.604, g: 0.604, b: 0.604, size: CGSize(width: 300, height: 200)))
    }

    private func layer(_ range: LuminanceRange?) -> Adjustments {
        var settings = LocalSettings()
        settings.exposure = -1
        var layer = LocalAdjustment(mask: .linear(LinearMask(start: .init(x: 0.5, y: 2), end: .init(x: 0.5, y: 3))), settings: settings)
        layer.luminanceRange = range
        var adjustments = Adjustments()
        adjustments.locals = [layer]
        return adjustments
    }

    private func sky(_ image: CIImage) throws -> Float { try probe.average(of: image, in: CGRect(x: 20, y: 50, width: 60, height: 100)).luminance }
    private func steeple(_ image: CIImage) throws -> Float { try probe.average(of: image, in: CGRect(x: 135, y: 50, width: 30, height: 100)).luminance }

    @Test func aGraduatedFilterOnTheSkySparesTheSteeple() throws {
        MemoryFuse.arm()
        let everything = stage.apply(layer(nil), to: steepleInTheSky)
        #expect(abs(try sky(everything) - 0.302) < 0.01)
        #expect(abs(try steeple(everything) - 0.0165) < 0.002)

        let brightOnly = stage.apply(layer(LuminanceRange(lower: 0.5, upper: 1, softness: 0.1)), to: steepleInTheSky)
        #expect(abs(try sky(brightOnly) - 0.302) < 0.01)
        #expect(abs(try steeple(brightOnly) - 0.033) < 0.001)
    }

    @Test func theRangeCanPickTheShadowsInstead() throws {
        MemoryFuse.arm()
        let darkOnly = stage.apply(layer(LuminanceRange(lower: 0, upper: 0.4, softness: 0.1)), to: steepleInTheSky)
        #expect(abs(try sky(darkOnly) - 0.604) < 0.005)
        #expect(abs(try steeple(darkOnly) - 0.0165) < 0.002)
    }

    /// Found on a real photo: the pixels of an edge are a mix of both sides, mid-tones between
    /// a bright sky and a dark lamp post. Left out of a range of highlights, they kept their
    /// brightness next to a sky made two stops darker, and drew a bright line around the post.
    @Test func noBrightLineIsLeftAroundWhatStandsInTheSky() throws {
        MemoryFuse.arm()
        // Screen-sized, so that the mask grows by a couple of pixels: sky, one column of edge, post.
        let sky = PixelProbe.swatch(r: 0.604, g: 0.604, b: 0.604, size: CGSize(width: 2500, height: 120))
        let edge = PixelProbe.swatch(r: 0.3, g: 0.3, b: 0.3, size: CGSize(width: 1, height: 120)).transformed(by: CGAffineTransform(translationX: 1200, y: 0))
        let post = PixelProbe.swatch(r: 0.033, g: 0.033, b: 0.033, size: CGSize(width: 100, height: 120)).transformed(by: CGAffineTransform(translationX: 1201, y: 0))
        let picture = post.composited(over: edge.composited(over: sky))

        var adjustments = layer(LuminanceRange(lower: 0.7, upper: 1, softness: 0.1))
        adjustments.locals[0].settings.exposure = -2
        let output = stage.apply(adjustments, to: picture)
        let darkenedSky = try probe.average(of: output, in: CGRect(x: 1100, y: 40, width: 50, height: 40)).luminance
        let edgeAfter = try probe.average(of: output, in: CGRect(x: 1200, y: 40, width: 1, height: 40)).luminance
        #expect(abs(darkenedSky - 0.151) < 0.01)
        #expect(edgeAfter <= darkenedSky + 0.005, "the edge is at \(edgeAfter), brighter than the sky next to it (\(darkenedSky))")
        // The post itself, past its rim, is spared.
        #expect(abs(try probe.average(of: output, in: CGRect(x: 1230, y: 40, width: 40, height: 40)).luminance - 0.033) < 0.002)
    }

    /// The range is read off the picture as the layer finds it, on display levels: highlights
    /// beyond display white (a RAW file has some) are highlights.
    @Test func highlightsBeyondDisplayWhiteAreInTheHighlights() throws {
        MemoryFuse.arm()
        // A swatch cannot be brighter than white: pushed a stop up, it is (1.8 in linear light).
        let push = CIFilter.exposureAdjust()
        push.inputImage = PixelProbe.swatch(r: 0.9, g: 0.9, b: 0.9)
        push.ev = 1
        let hot = try #require(push.outputImage)
        #expect(try probe.average(of: hot).luminance > 1.7)
        let measured = try probe.average(of: stage.apply(layer(LuminanceRange(lower: 0.8, upper: 1, softness: 0.1)), to: hot)).luminance
        #expect(abs(measured - 0.9) < 0.02)
    }
}
