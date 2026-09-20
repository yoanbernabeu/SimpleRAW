import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct ScalingRGBTests {
    let probe = PixelProbe()

    @Test func scalesAndShiftsColorAndLeavesAlphaAlone() throws {
        MemoryFuse.arm()
        let swatch = PixelProbe.swatch(r: 0.2, g: 0.4, b: 0.6)
        let scaled = try probe.average(of: swatch.scalingRGB(by: 0.5, bias: 0.1))
        #expect(abs(scaled.r - 0.2) < 0.002 && abs(scaled.g - 0.3) < 0.002 && abs(scaled.b - 0.4) < 0.002)
        let plain = try probe.average(of: swatch.scalingRGB(by: 2))
        #expect(abs(plain.r - 0.4) < 0.002 && abs(plain.b - 1.2) < 0.004)
        // Opaque still: laid over white, nothing of the white shows through.
        let over = swatch.scalingRGB(by: 0.5).composited(over: PixelProbe.swatch(r: 1, g: 1, b: 1))
        #expect(abs(try probe.average(of: over).r - 0.1) < 0.002)
    }

    @Test func doingNothingCostsNothing() {
        let swatch = PixelProbe.swatch(r: 0.2, g: 0.4, b: 0.6)
        #expect(swatch.scalingRGB(by: 1) === swatch)
    }
}

@Suite struct Rec709Tests {
    @Test func luminanceWeightsAreTheOnesOfTheStandard() {
        #expect(Rec709.luma(SIMD3(1, 1, 1)) == 1)
        #expect(abs(Rec709.luma(SIMD3(0, 1, 0)) - 0.7152) < 1e-6)
        #expect(ColorGradingTransform.luma(SIMD3(0.2, 0.5, 0.9)) == Rec709.luma(SIMD3(0.2, 0.5, 0.9)))
        #expect(Rec709.vector == CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0))
    }
}

@Suite struct CaptureDateTests {
    /// EXIF writes local time with no zone; read as if UTC, like the rest of the catalog.
    @Test func anExifDateIsReadAsWrittenOnTheCamera() throws {
        let date = try #require(RawInfo.date(fromExif: "2026:09:11 11:14:40"))
        #expect(ISO8601DateFormatter().string(from: date) == "2026-09-11T11:14:40Z")
    }

    @Test(arguments: ["", "yesterday", "2026-09-11 11:14:40", "2026:13:45 99:99:99", "0000:00:00 00:00:00", "    :  :     :  :  "])
    func whatIsNotADateIsNone(text: String) {
        #expect(RawInfo.date(fromExif: text) == nil)
    }

    @Test(.enabled(if: Sample.url != nil, "Needs a DNG in Samples/"))
    func aPhotoSaysWhenItWasTaken() throws {
        let info = try RawSource(url: try #require(Sample.url)).info
        let text = try #require(info.captureDateText)
        #expect(info.captureDate == RawInfo.date(fromExif: text) && info.captureDate != nil)
    }
}
