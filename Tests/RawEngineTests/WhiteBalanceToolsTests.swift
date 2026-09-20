import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct WhiteBalancePresetTests {
    let asShot = WhiteBalance(temperature: 5000, tint: 10)

    @Test func asShotClearsTheOverride() {
        var adjustments = Adjustments()
        adjustments.setTemperature(7000, asShot: asShot)
        WhiteBalancePreset.asShot.apply(to: &adjustments, asShot: asShot)
        #expect(adjustments == Adjustments())
    }

    @Test func presetsGoFromWarmLightToColdLight() {
        let kelvins = [WhiteBalancePreset.tungsten, .fluorescent, .daylight, .cloudy, .shade].compactMap(\.whiteBalance?.temperature)
        #expect(kelvins == kelvins.sorted() && kelvins.count == 5)
    }

    @Test func aPresetSetsBothValues() {
        var adjustments = Adjustments()
        WhiteBalancePreset.cloudy.apply(to: &adjustments, asShot: asShot)
        #expect(adjustments.whiteBalance == WhiteBalancePreset.cloudy.whiteBalance)
    }

    @Test func thePresetInUseIsRecognized() {
        var adjustments = Adjustments()
        #expect(WhiteBalancePreset.matching(adjustments) == .asShot)
        WhiteBalancePreset.shade.apply(to: &adjustments, asShot: asShot)
        #expect(WhiteBalancePreset.matching(adjustments) == .shade)
        adjustments.setTint(33, asShot: asShot)
        #expect(WhiteBalancePreset.matching(adjustments) == nil)
    }
}

@Suite(.enabled(if: Sample.all.count >= 2, "Needs the samples"))
struct WhiteBalancePickerTests {
    let probe = PixelProbe()

    /// The last sample is a street scene with a white wall, which the camera rendered
    /// bluish: clicking it must make it neutral. (0.88, 0.5) is on the wall, right of the
    /// window; the point was checked by measuring, the first guess landed on dark glass.
    @Test func pickingANeutralSurfaceMakesItNeutral() throws {
        let source = try RawSource(url: try #require(Sample.all.last))
        let point = NormalizedPoint(x: 0.88, y: 0.5)
        let picked = try #require(source.whiteBalance(neutralAt: point))

        func cast(_ adjustments: Adjustments) throws -> Float {
            let image = try source.image(adjustments: adjustments, scaleFactor: 0.125)
            let center = point.location(in: image.extent)
            let pixel = try probe.average(of: image, in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
            return pixel.chroma / max(pixel.g, 0.001)
        }
        var corrected = Adjustments()
        corrected.whiteBalance = picked
        #expect(try cast(corrected) < cast(Adjustments()))
        #expect(try cast(corrected) < 0.04)
    }

    @Test func pickingLeavesTheSourceAsItWas() throws {
        let source = try RawSource(url: try #require(Sample.all.last))
        let before = try probe.average(of: source.image(scaleFactor: 0.125))
        _ = source.whiteBalance(neutralAt: NormalizedPoint(x: 0.88, y: 0.5))
        let after = try probe.average(of: source.image(scaleFactor: 0.125))
        #expect(abs(before.r - after.r) < 0.001 && abs(before.b - after.b) < 0.001)
    }

    @Test func aPointOutsideThePictureGivesNothing() throws {
        let source = try RawSource(url: try #require(Sample.all.last))
        #expect(source.whiteBalance(neutralAt: NormalizedPoint(x: 1.4, y: 0.5)) == nil)
    }
}
