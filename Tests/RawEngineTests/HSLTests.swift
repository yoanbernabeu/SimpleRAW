import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct HSLMathTests {
    let red = SIMD3<Float>(0.9, 0.1, 0.1)
    let blue = SIMD3<Float>(0.1, 0.1, 0.9)

    @Test func neutralSettingsChangeNothing() {
        let transform = HSLTransform(HSLAdjustments())
        for color in [red, blue, SIMD3<Float>(0.3, 0.6, 0.2), SIMD3<Float>(0.5, 0.5, 0.5)] {
            #expect(distance(transform.apply(to: color), color) < 1e-5)
        }
    }

    @Test func graysAreNeverAffected() {
        var hsl = HSLAdjustments()
        for band in ColorBandName.allCases {
            hsl[band] = ColorBand(hue: 100, saturation: 100, luminance: 100)
        }
        let gray = SIMD3<Float>(0.4, 0.4, 0.4)
        #expect(distance(HSLTransform(hsl).apply(to: gray), gray) < 1e-5)
    }

    @Test func aBandOnlyTouchesItsOwnHues() {
        var hsl = HSLAdjustments()
        hsl[.red].saturation = -100
        let transform = HSLTransform(hsl)
        let desaturated = transform.apply(to: red)
        #expect(desaturated.max() - desaturated.min() < 0.01)
        #expect(distance(transform.apply(to: blue), blue) < 1e-5)
    }

    @Test func aHueBetweenTwoBandsIsSharedByBoth() {
        // 45° sits halfway between orange (30°) and yellow (60°).
        let weights = HSLTransform.bandWeights(forHue: 45)
        #expect(abs(weights[.orange]! - 0.5) < 1e-6)
        #expect(abs(weights[.yellow]! - 0.5) < 1e-6)
        #expect(abs(weights.values.reduce(0, +) - 1) < 1e-6)
    }

    @Test func aHueOnABandCenterBelongsToItAlone() {
        #expect(HSLTransform.bandWeights(forHue: 240) == [.blue: 1])
        // The hue circle wraps: 359° is almost red, with a touch of magenta.
        let nearRed = HSLTransform.bandWeights(forHue: 359)
        #expect(nearRed[.red]! > 0.95 && nearRed[.magenta]! > 0)
    }

    @Test func positiveHueShiftsRedTowardOrange() {
        var hsl = HSLAdjustments()
        hsl[.red].hue = 100
        let shifted = HSLTransform(hsl).apply(to: red)
        #expect(shifted.y > red.y + 0.1)
        #expect(abs(shifted.z - red.z) < 0.02)
    }

    @Test func luminanceBrightensTheBand() {
        var hsl = HSLAdjustments()
        hsl[.blue].luminance = 100
        let brightened = HSLTransform(hsl).apply(to: blue)
        #expect(brightened.min() > blue.min())
        #expect(brightened.z >= blue.z)
    }
}

@Suite struct HSLDocumentTests {
    @Test func roundTripsThroughJSON() throws {
        var adjustments = Adjustments()
        adjustments.hsl[.orange] = ColorBand(hue: -10, saturation: 25, luminance: 5)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: adjustments.jsonData())
        #expect(decoded == adjustments)
    }

    @Test func onlyEditedBandsAreWritten() throws {
        var adjustments = Adjustments()
        adjustments.hsl[.blue].saturation = 40
        // The `hsl` object itself: other panels have a "red", a "blue", an "orange" of their own.
        let document = try #require(try JSONSerialization.jsonObject(with: adjustments.jsonData()) as? [String: Any])
        let bands = try #require(document["hsl"] as? [String: [String: Double]])
        #expect(bands == ["blue": ["hue": 0, "saturation": 40, "luminance": 0]])
    }

    @Test func resettingABandMakesTheDocumentNeutralAgain() {
        var adjustments = Adjustments()
        adjustments.hsl[.green].hue = 30
        adjustments.hsl[.green].hue = 0
        #expect(adjustments == Adjustments())
        #expect(adjustments.hsl.isNeutral)
    }

    @Test func aPresetMayCarryAPartialBand() throws {
        let preset = Data(#"{"hsl": {"aqua": {"saturation": -20}}}"#.utf8)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: preset)
        #expect(decoded.hsl[.aqua] == ColorBand(hue: 0, saturation: -20, luminance: 0))
    }
}

@Suite struct HSLStageTests {
    let probe = PixelProbe()
    let stage = HSLStage()
    let redSwatch = PixelProbe.swatch(r: 0.6, g: 0.03, b: 0.03)
    let blueSwatch = PixelProbe.swatch(r: 0.03, g: 0.03, b: 0.6)

    @Test func desaturatesTheChosenBand() throws {
        var adjustments = Adjustments()
        adjustments.hsl[.red].saturation = -100
        #expect(try probe.average(of: stage.apply(adjustments, to: redSwatch)).chroma < 0.03)
    }

    @Test func leavesOtherColorsAlone() throws {
        var adjustments = Adjustments()
        adjustments.hsl[.red].saturation = -100
        let output = try probe.average(of: stage.apply(adjustments, to: blueSwatch))
        #expect(abs(output.b - 0.6) < 0.02)
        #expect(output.r < 0.06)
    }

    @Test func doesNotServeAStaleTable() throws {
        var adjustments = Adjustments()
        adjustments.hsl[.red].saturation = -100
        _ = stage.apply(adjustments, to: redSwatch)
        adjustments.hsl[.red].saturation = -10
        #expect(try probe.average(of: stage.apply(adjustments, to: redSwatch)).chroma > 0.3)
    }

    /// Catches a lookup table written with its axes in the wrong order.
    @Test func shiftsRedTowardOrangeNotTowardMagenta() throws {
        var adjustments = Adjustments()
        adjustments.hsl[.red].hue = 100
        let output = try probe.average(of: stage.apply(adjustments, to: redSwatch))
        #expect(output.g > 0.1)
        #expect(output.b < 0.06)
    }
}

private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    ((a - b) * (a - b)).sum().squareRoot()
}
