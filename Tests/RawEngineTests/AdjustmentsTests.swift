import Foundation
import Testing
@testable import RawEngine

@Suite struct AdjustmentsTests {
    /// Every field, not four of them: see `AdjustmentGroupTests.edited`.
    @Test func roundTripsThroughJSON() throws {
        let edited = AdjustmentGroupTests.edited
        #expect(try JSONDecoder().decode(Adjustments.self, from: edited.jsonData()) == edited)
    }

    /// Thumbnails are fingerprinted on this form: changing it would re-render every one.
    @Test func documentsAreWrittenSortedAndIndented() throws {
        let data = try JSONEncoder.document.encode(["b": 1, "a": 2])
        #expect(String(decoding: data, as: UTF8.self) == "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
        var adjustments = Adjustments()
        adjustments.contrast = 20
        #expect(try adjustments.jsonData() == JSONEncoder.document.encode(adjustments))
        var preset = ExportPreset(name: "Web")
        preset.options.longEdge = 2048
        #expect(try preset.encoded() == JSONEncoder.document.encode(preset))
    }

    @Test func partialDocumentFallsBackToNeutral() throws {
        let preset = Data(#"{"contrast": 20, "vibrance": 15}"#.utf8)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: preset)

        var expected = Adjustments()
        expected.contrast = 20
        expected.vibrance = 15
        #expect(decoded == expected)
    }

    @Test func rejectsDocumentsFromTheFuture() {
        let document = Data(#"{"version": 99}"#.utf8)
        #expect(throws: RawEngineError.unsupportedAdjustmentsVersion(99)) {
            try JSONDecoder().decode(Adjustments.self, from: document)
        }
    }
}

@Suite struct ToneCurveTests {
    @Test func neutralAdjustmentsSkipTheStage() {
        #expect(ToneCurve.points(for: Adjustments()) == nil)
    }

    @Test func negativeHighlightsAreLeftToTheAdaptiveStage() {
        var adjustments = Adjustments()
        adjustments.highlights = -80
        #expect(ToneCurve.points(for: adjustments) == nil)
    }

    @Test func contrastBuildsAnSCurve() throws {
        var adjustments = Adjustments()
        adjustments.contrast = 50
        let points = try #require(ToneCurve.points(for: adjustments))
        #expect(points[1].y < 0.25)
        #expect(points[2].y == 0.5)
        #expect(points[3].y > 0.75)
    }

    @Test(arguments: [-100.0, -40, 0, 40, 100], [-100.0, 0, 100])
    func curveStaysMonotonic(contrast: Double, endpoints: Double) throws {
        var adjustments = Adjustments()
        adjustments.contrast = contrast
        adjustments.highlights = 100
        adjustments.whites = endpoints
        adjustments.blacks = -endpoints
        let points = try #require(ToneCurve.points(for: adjustments))
        for (previous, next) in zip(points, points.dropFirst()) {
            #expect(next.x > previous.x)
            #expect(next.y >= previous.y)
        }
    }

    @Test func outOfRangeSlidersAreClamped() {
        var wild = Adjustments()
        wild.contrast = 400
        var max = Adjustments()
        max.contrast = 100
        #expect(ToneCurve.points(for: wild) == ToneCurve.points(for: max))
    }
}

@Suite struct WhiteBalanceEditingTests {
    let asShot = WhiteBalance(temperature: 5000, tint: 10)

    @Test func resolvesToAsShotUntilEdited() {
        #expect(Adjustments().whiteBalance(orAsShot: asShot) == asShot)
    }

    @Test func editingTemperatureKeepsTheAsShotTint() {
        var adjustments = Adjustments()
        adjustments.setTemperature(6500, asShot: asShot)
        #expect(adjustments.whiteBalance == WhiteBalance(temperature: 6500, tint: 10))
    }

    @Test func editingTintKeepsAnEarlierTemperatureEdit() {
        var adjustments = Adjustments()
        adjustments.setTemperature(6500, asShot: asShot)
        adjustments.setTint(-5, asShot: asShot)
        #expect(adjustments.whiteBalance == WhiteBalance(temperature: 6500, tint: -5))
    }

    @Test func goingBackToAsShotClearsTheOverride() {
        var adjustments = Adjustments()
        adjustments.setTemperature(6500, asShot: asShot)
        adjustments.setTemperature(asShot.temperature, asShot: asShot)
        #expect(adjustments == Adjustments())
    }
}
