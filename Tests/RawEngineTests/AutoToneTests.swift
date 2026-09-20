import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// Auto is a pure decision on a few statistics: it is specified here on typical pictures,
/// described by the display levels (0...1) of their luminance percentiles.
@Suite struct AutoToneTests {
    private func stats(p1: Double, p5: Double, p25: Double, p50: Double, p75: Double, p95: Double, p99: Double, saturation: Double = 0.3) -> ToneStatistics {
        ToneStatistics(p1: p1, p5: p5, p25: p25, p50: p50, p75: p75, p95: p95, p99: p99, meanSaturation: saturation)
    }

    @Test func aWellExposedPictureIsBarelyTouched() {
        let result = AutoTone.settings(for: stats(p1: 0.03, p5: 0.08, p25: 0.28, p50: 0.45, p75: 0.64, p95: 0.88, p99: 0.95))
        #expect(abs(result.exposure) < 0.15)
        #expect(abs(result.contrast) <= 10 && result.shadows <= 10 && result.highlights >= -10)
    }

    @Test func aDarkPictureIsBrightenedAndItsShadowsOpened() {
        let result = AutoTone.settings(for: stats(p1: 0.0, p5: 0.01, p25: 0.06, p50: 0.15, p75: 0.3, p95: 0.55, p99: 0.7))
        #expect(result.exposure > 0.6)
        #expect(result.shadows > 0)
    }

    @Test func aBrightPictureIsBroughtDownAndItsHighlightsRecovered() {
        let result = AutoTone.settings(for: stats(p1: 0.2, p5: 0.35, p25: 0.6, p50: 0.78, p75: 0.9, p95: 0.98, p99: 1.0))
        #expect(result.exposure < -0.3)
        #expect(result.highlights < 0)
    }

    @Test func aFlatPictureGetsContrastAndTrueBlacksAndWhites() {
        let result = AutoTone.settings(for: stats(p1: 0.25, p5: 0.3, p25: 0.4, p50: 0.47, p75: 0.54, p95: 0.62, p99: 0.68))
        #expect(result.contrast > 10)
        #expect(result.blacks < 0 && result.whites > 0)
    }

    /// Brightening must not blow the highlights a picture already has.
    @Test func exposureIsHeldBackByBrightHighlights() {
        let backlit = stats(p1: 0.0, p5: 0.01, p25: 0.05, p50: 0.14, p75: 0.4, p95: 0.95, p99: 0.99)
        let plainDark = stats(p1: 0.0, p5: 0.01, p25: 0.05, p50: 0.14, p75: 0.3, p95: 0.5, p99: 0.6)
        #expect(AutoTone.settings(for: backlit).exposure < AutoTone.settings(for: plainDark).exposure)
        #expect(AutoTone.settings(for: backlit).shadows > 15)
    }

    @Test func mutedPicturesGetMoreVibranceThanVividOnes() {
        let muted = stats(p1: 0.03, p5: 0.08, p25: 0.28, p50: 0.45, p75: 0.64, p95: 0.88, p99: 0.95, saturation: 0.1)
        let vivid = stats(p1: 0.03, p5: 0.08, p25: 0.28, p50: 0.45, p75: 0.64, p95: 0.88, p99: 0.95, saturation: 0.6)
        #expect(AutoTone.settings(for: muted).vibrance > AutoTone.settings(for: vivid).vibrance)
    }

    @Test(arguments: [0.0, 0.2, 0.5, 0.8, 1.0])
    func settingsAlwaysStayWithinSliderRanges(level: Double) {
        let result = AutoTone.settings(for: stats(p1: level, p5: level, p25: level, p50: level, p75: level, p95: level, p99: level))
        #expect((-2.0...2.0).contains(result.exposure))
        for value in [result.contrast, result.highlights, result.shadows, result.whites, result.blacks, result.vibrance] {
            #expect((-100.0...100.0).contains(value) && !value.isNaN)
        }
    }

    @Test func applyingAutoReplacesLightAndVibranceOnly() {
        var adjustments = Adjustments()
        adjustments.exposure = -2
        adjustments.clarity = 30
        adjustments.saturation = 12
        let result = AutoTone.settings(for: stats(p1: 0.0, p5: 0.01, p25: 0.06, p50: 0.15, p75: 0.3, p95: 0.55, p99: 0.7))
        result.apply(to: &adjustments)
        #expect(adjustments.exposure == result.exposure && adjustments.shadows == result.shadows)
        #expect(adjustments.clarity == 30 && adjustments.saturation == 12)
    }
}

@Suite struct ToneAnalyzerTests {
    @Test func measuresTheLevelsOfAPicture() throws {
        // Left half dark (sRGB ~0.2), right half light (sRGB ~0.8).
        let dark = PixelProbe.swatch(r: 0.033, g: 0.033, b: 0.033, size: CGSize(width: 100, height: 100))
        let picture = dark.composited(over: PixelProbe.swatch(r: 0.6, g: 0.6, b: 0.6, size: CGSize(width: 200, height: 100)))
        let stats = try ToneAnalyzer().statistics(of: picture)
        #expect(abs(stats.p5 - 0.2) < 0.03 && abs(stats.p25 - 0.2) < 0.03)
        #expect(abs(stats.p75 - 0.8) < 0.03 && abs(stats.p95 - 0.8) < 0.03)
        #expect(stats.meanSaturation < 0.02)
    }

    @Test func measuresSaturation() throws {
        let vivid = PixelProbe.swatch(r: 0.8, g: 0.05, b: 0.05)
        #expect(try ToneAnalyzer().statistics(of: vivid).meanSaturation > 0.7)
    }
}

/// Enhance is a recipe over sliders that already exist. It is folded into the effective
/// settings before the pipeline runs, so that it costs no pass of its own: run as a stage, it
/// blurred the picture a second time for dehaze and clarity, and broke the frame budget.
@Suite struct EnhanceTests {
    let probe = PixelProbe()

    @Test func neutralEnhanceChangesNoSetting() {
        var adjustments = Adjustments()
        adjustments.clarity = 20
        #expect(adjustments.foldingEnhance() == adjustments)
    }

    @Test func enhanceAddsToTheSlidersItIsMadeOfAndIsSpent() {
        var adjustments = Adjustments()
        adjustments.enhance = 50
        adjustments.clarity = 10
        let folded = adjustments.foldingEnhance()
        #expect(folded.enhance == 0)
        #expect(folded.clarity > 10 && folded.shadows > 0 && folded.highlights < 0 && folded.vibrance > 0)
        // Twice the slider, twice the recipe.
        adjustments.enhance = 100
        #expect(abs(adjustments.foldingEnhance().shadows - folded.shadows * 2) < 1e-9)
    }

    @Test func slidersStayWithinTheirRange() {
        var adjustments = Adjustments()
        adjustments.enhance = 100
        adjustments.shadows = 90
        adjustments.highlights = -95
        let folded = adjustments.foldingEnhance()
        #expect(folded.shadows == 100 && folded.highlights == -100)
    }

    /// Judged on real photos: at +30, halfway up the slider already turned a sky polarizer-blue
    /// and dune grass yellow. Color is the part of the recipe that shows first when overdone,
    /// so it stays well under what Auto may give a dull picture (30).
    @Test func theRecipeGoesEasyOnColor() {
        var adjustments = Adjustments()
        adjustments.enhance = 100
        #expect(adjustments.foldingEnhance().vibrance == 18)
        adjustments.enhance = 50
        #expect(adjustments.foldingEnhance().vibrance == 9)
    }

    @Test func thePipelineRunsNoStageOfItsOwnForEnhance() {
        #expect(!DevelopPipeline.standard.stages.contains { String(describing: type(of: $0)).contains("Enhance") })
    }

    @Test func oneSliderOpensShadowsAndWakesColorsUp() throws {
        let muted = PixelProbe.swatch(r: 0.05, g: 0.045, b: 0.04, size: CGSize(width: 200, height: 100))
            .composited(over: PixelProbe.swatch(r: 0.45, g: 0.4, b: 0.35, size: CGSize(width: 400, height: 100)))
        var adjustments = Adjustments()
        adjustments.enhance = 100
        let output = DevelopPipeline.standard.apply(adjustments, to: muted)
        let shadow = CGRect(x: 20, y: 20, width: 60, height: 60)
        let midtone = CGRect(x: 300, y: 20, width: 60, height: 60)
        #expect(try probe.average(of: output, in: shadow).luminance > probe.average(of: muted, in: shadow).luminance)
        #expect(try probe.average(of: output, in: midtone).chroma > probe.average(of: muted, in: midtone).chroma)
        #expect(output.extent == muted.extent)
    }
}
