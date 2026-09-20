import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct ColorGradingMathTests {
    let dark = SIMD3<Float>(0.12, 0.12, 0.12)
    let mid = SIMD3<Float>(0.5, 0.5, 0.5)
    let bright = SIMD3<Float>(0.9, 0.9, 0.9)

    @Test func neutralSettingsChangeNothing() {
        let transform = ColorGradingTransform(ColorGrading())
        for color in [dark, mid, bright, SIMD3<Float>(0.8, 0.3, 0.1)] {
            #expect(transform.apply(to: color) == color)
        }
    }

    @Test(arguments: [0.0, 0.1, 0.35, 0.5, 0.8, 1.0], [-100.0, 0, 100])
    func rangeWeightsAlwaysAddUpToOne(luma: Double, balance: Double) {
        let weights = ColorGradingTransform.rangeWeights(forLuma: luma, balance: balance)
        #expect(abs(weights.shadows + weights.midtones + weights.highlights - 1) < 1e-9)
        #expect(min(weights.shadows, weights.midtones, weights.highlights) >= 0)
    }

    @Test func eachRangeOwnsItsEndOfTheScale() {
        let black = ColorGradingTransform.rangeWeights(forLuma: 0, balance: 0)
        let gray = ColorGradingTransform.rangeWeights(forLuma: 0.5, balance: 0)
        let white = ColorGradingTransform.rangeWeights(forLuma: 1, balance: 0)
        #expect(black.shadows == 1)
        #expect(white.highlights == 1)
        #expect(gray.midtones > gray.shadows && gray.midtones > gray.highlights)
    }

    @Test func tintingShadowsBlueLeavesHighlightsAlone() {
        var grading = ColorGrading()
        grading[.shadows] = ColorWheel(hue: 240, saturation: 100)
        let transform = ColorGradingTransform(grading)
        let tinted = transform.apply(to: dark)
        #expect(tinted.z > tinted.x + 0.05)
        let untouched = transform.apply(to: bright)
        #expect(abs(untouched.z - untouched.x) < 0.02)
    }

    @Test func tintingHighlightsOrangeWarmsThemUp() {
        var grading = ColorGrading()
        grading[.highlights] = ColorWheel(hue: 30, saturation: 80)
        let tinted = ColorGradingTransform(grading).apply(to: bright)
        #expect(tinted.x > tinted.z + 0.05)
    }

    /// A tint is a color shift, not a brightness change.
    @Test func tintingPreservesLuma() {
        var grading = ColorGrading()
        grading[.midtones] = ColorWheel(hue: 120, saturation: 100)
        let tinted = ColorGradingTransform(grading).apply(to: mid)
        #expect(abs(ColorGradingTransform.luma(tinted) - ColorGradingTransform.luma(mid)) < 0.01)
    }

    @Test func luminanceMovesItsRangeOnly() {
        var grading = ColorGrading()
        grading[.shadows].luminance = 100
        let transform = ColorGradingTransform(grading)
        #expect(transform.apply(to: dark).x > dark.x + 0.05)
        #expect(abs(transform.apply(to: bright).x - bright.x) < 0.01)
    }

    @Test func positiveBalanceHandsMoreOfTheImageToHighlights() {
        var grading = ColorGrading()
        grading[.highlights] = ColorWheel(hue: 30, saturation: 100)
        grading.balance = -60
        let towardShadows = ColorGradingTransform(grading).apply(to: mid)
        grading.balance = 60
        let towardHighlights = ColorGradingTransform(grading).apply(to: mid)
        #expect(towardHighlights.x - towardHighlights.z > towardShadows.x - towardShadows.z)
    }
}

@Suite struct ColorGradingDocumentTests {
    @Test func roundTripsThroughJSON() throws {
        var adjustments = Adjustments()
        adjustments.grading[.shadows] = ColorWheel(hue: 220, saturation: 30, luminance: -5)
        adjustments.grading.balance = 15
        let decoded = try JSONDecoder().decode(Adjustments.self, from: adjustments.jsonData())
        #expect(decoded == adjustments)
    }

    @Test func aPresetMayCarryASingleWheel() throws {
        let preset = Data(#"{"grading": {"highlights": {"hue": 40, "saturation": 20}}}"#.utf8)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: preset)
        #expect(decoded.grading[.highlights] == ColorWheel(hue: 40, saturation: 20))
        #expect(decoded.grading[.shadows] == ColorWheel())
    }

    /// A hue without saturation tints nothing: it must not make the document look edited.
    @Test func aWheelBackAtItsCenterIsNeutral() {
        var adjustments = Adjustments()
        adjustments.grading[.midtones] = ColorWheel(hue: 200, saturation: 50)
        adjustments.grading[.midtones].saturation = 0
        #expect(adjustments == Adjustments())
    }
}

@Suite struct ColorGradingStageTests {
    let probe = PixelProbe()
    let stage = ColorGradingStage()

    @Test func tintsTheShadowsOfAnImage() throws {
        var adjustments = Adjustments()
        adjustments.grading[.shadows] = ColorWheel(hue: 240, saturation: 100)
        let dark = PixelProbe.swatch(r: 0.02, g: 0.02, b: 0.02)
        let bright = PixelProbe.swatch(r: 0.8, g: 0.8, b: 0.8)
        let tinted = try probe.average(of: stage.apply(adjustments, to: dark))
        #expect(tinted.b > tinted.r * 1.5)
        #expect(try probe.average(of: stage.apply(adjustments, to: bright)).chroma < 0.03)
    }
}
