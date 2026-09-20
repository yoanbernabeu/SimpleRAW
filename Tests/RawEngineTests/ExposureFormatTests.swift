import Foundation
import Testing
@testable import RawEngine

@Suite struct ExposureFormatTests {
    let locale = Locale(identifier: "en_US")

    @Test func fastShutterSpeedsAreFractions() {
        #expect(ExposureFormat.shutterSpeed(1.0 / 400, locale: locale) == "1/400 s")
        #expect(ExposureFormat.shutterSpeed(0.0166667, locale: locale) == "1/60 s")
    }

    @Test func slowShutterSpeedsAreSeconds() {
        #expect(ExposureFormat.shutterSpeed(2.5, locale: locale) == "2.5 s")
        #expect(ExposureFormat.shutterSpeed(1, locale: locale) == "1 s")
    }

    @Test func apertureKeepsOneDecimalWhenNeeded() {
        #expect(ExposureFormat.aperture(7.1, locale: locale) == "f/7.1")
        #expect(ExposureFormat.aperture(8, locale: locale) == "f/8")
    }

    @Test func focalLengthIsRoundedToATenth() {
        #expect(ExposureFormat.focalLength(18.299999, locale: locale) == "18.3 mm")
        #expect(ExposureFormat.focalLength(50, locale: locale) == "50 mm")
    }

    @Test func isoIsPlain() {
        #expect(ExposureFormat.iso(6400) == "ISO 6400")
    }
}
