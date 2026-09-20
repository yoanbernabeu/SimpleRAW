import Foundation
import Testing
@testable import RawEngine

/// A look is dosed from 0 to 100 %: a pure function of the current settings and the look.
@Suite struct LookAmountTests {
    let edited = AdjustmentGroupTests.edited

    private var photo: Adjustments {
        var photo = Adjustments()
        photo.exposure = -1
        photo.contrast = 30
        photo.vignetting = 20
        photo.curves.rgb.insert(.init(x: 0.5, y: 0.4))
        return photo
    }

    @Test(arguments: [Set(AdjustmentGroup.allCases), [.light, .color], [.curve], [.grading, .hsl]] as [Set<AdjustmentGroup>])
    func atNothingThePhotoIsUntouchedAtFullTheLookIsApplied(groups: Set<AdjustmentGroup>) {
        let look = Preset(name: "Look", capturing: edited, groups: groups)
        #expect(look.applied(to: photo, amount: 0) == photo)
        var applied = photo
        look.apply(to: &applied)
        #expect(look.applied(to: photo, amount: 1) == applied)
        // Out of range is the nearest end, and what is not a number changes nothing.
        #expect(look.applied(to: photo, amount: 7) == applied && look.applied(to: photo, amount: -1) == photo)
        #expect(look.applied(to: photo, amount: .nan) == photo)
    }

    @Test func slidersGoPartOfTheWayAndTheRestIsLeftAlone() {
        let look = Preset(name: "Light", capturing: edited, groups: [.light])
        let half = look.applied(to: photo, amount: 0.5)
        #expect(half.exposure == -0.25 && half.contrast == 20 && half.shadows == 15)
        #expect(half.vignetting == 20 && half.curves == photo.curves && half.vibrance == 0)
        #expect(look.applied(to: photo, amount: 0.25).contrast == 25)
    }

    /// A look no longer wipes the curve of the photo out: it pulls it toward its own.
    @Test func curvesMeetHalfway() {
        var fade = Adjustments()
        fade.curves.rgb = Curve(points: [.init(x: 0, y: 0.1), .init(x: 0.25, y: 0.3), .init(x: 1, y: 0.9)])
        let look = Preset(name: "Fade", capturing: fade, groups: [.curve])
        let half = look.applied(to: photo, amount: 0.5).curves.rgb
        for x in [0.0, 0.1, 0.25, 0.5, 0.8, 1.0] {
            let expected = (photo.curves.rgb.value(at: x) + fade.curves.rgb.value(at: x)) / 2
            #expect(abs(half.value(at: x) - expected) < 0.01, "at \(x)")
        }
        #expect(half.points.count <= AdjustmentLimits.curvePoints)
        #expect(look.applied(to: photo, amount: 0.5).curves.red.isIdentity)
    }

    @Test func aCurveOfManyPointsStaysWithinTheLimit() {
        func busy(_ offset: Double) -> Curve {
            Curve(points: (0..<16).map { .init(x: (Double($0) + offset) / 16, y: min(1, Double($0) / 15)) })
        }
        var (current, target) = (Adjustments(), Adjustments())
        (current.curves.rgb, target.curves.rgb) = (busy(0), busy(0.5))
        let half = Preset(name: "Busy", capturing: target, groups: [.curve]).applied(to: current, amount: 0.5).curves.rgb
        #expect(half.points.count <= AdjustmentLimits.curvePoints)
        #expect(abs(half.value(at: 0.5) - (current.curves.rgb.value(at: 0.5) + target.curves.rgb.value(at: 0.5)) / 2) < 0.02)
    }

    /// From 350° to 10° is 20° through red, not 340° through every other color.
    @Test func huesTakeTheShortWayRound() {
        var (current, target) = (Adjustments(), Adjustments())
        current.grading[.shadows] = ColorWheel(hue: 350, saturation: 40)
        target.grading[.shadows] = ColorWheel(hue: 10, saturation: 20)
        let half = Preset(name: "Grade", capturing: target, groups: [.grading]).applied(to: current, amount: 0.5).grading[.shadows]
        #expect(abs(half.hue - 0) < 1e-9 || abs(half.hue - 360) < 1e-9)
        #expect(half.saturation == 30)
        // A wheel with no saturation has no hue to start from: the look's hue, fading in.
        current.grading[.shadows] = ColorWheel()
        let fadingIn = Preset(name: "Grade", capturing: target, groups: [.grading]).applied(to: current, amount: 0.5).grading[.shadows]
        #expect(fadingIn.hue == 10 && fadingIn.saturation == 10)
    }

    /// A mood is the one thing a look carries that fades by itself: its own amount.
    @Test func aMoodFadesInByItsAmountAndOnlySwitchesForAnotherOne() {
        let look = Preset(name: "Teal", capturing: edited, groups: [.grading])
        #expect(look.applied(to: Adjustments(), amount: 0.25).lut == LUTSetting(name: "Teal", amount: 20))
        #expect(look.applied(to: Adjustments(), amount: 0).lut == nil)

        // Away from a mood the photo already wears: its amount goes down to nothing.
        var worn = Adjustments()
        worn.lut = LUTSetting(name: "Teal", amount: 60)
        let none = Preset(name: "None", capturing: Adjustments(), groups: [.grading])
        #expect(none.applied(to: worn, amount: 0.5).lut == LUTSetting(name: "Teal", amount: 30))
        #expect(none.applied(to: worn, amount: 1).lut == nil)

        // Two different tables: nothing sits between them, so one comes in at the middle.
        #expect(look.applied(to: worn, amount: 0.4).lut?.name == "Teal")
        var other = Adjustments()
        other.lut = LUTSetting(name: "Faded", amount: 100)
        let swap = Preset(name: "Faded", capturing: other, groups: [.grading])
        #expect(swap.applied(to: worn, amount: 0.4).lut == worn.lut)
        #expect(swap.applied(to: worn, amount: 0.6).lut == other.lut)
    }

    @Test func colorBandsGoPartOfTheWay() {
        let look = Preset(name: "Blue", capturing: edited, groups: [.hsl])
        #expect(look.applied(to: Adjustments(), amount: 0.5).hsl[.blue].saturation == -15)
    }

    /// Black and white cannot be half on: it comes in at the middle of the slider, with a mix
    /// that follows the amount.
    @Test func whatCannotBeInterpolatedSwitchesAtTheMiddle() {
        let look = Preset(name: "B&W", capturing: edited, groups: [.color, .geometry, .optics])
        let (before, after) = (look.applied(to: Adjustments(), amount: 0.49), look.applied(to: Adjustments(), amount: 0.5))
        #expect(!before.blackAndWhite.isEnabled && after.blackAndWhite.isEnabled)
        #expect(after.blackAndWhite.red == 10 && before.blackAndWhite.red == 9.8)
        #expect(before.geometry == Adjustments().geometry && after.geometry == edited.geometry)
        #expect(before.lensCorrection && !after.lensCorrection)
        #expect(after.vibrance == 7.5 && after.vignetting == 17.5)
    }

    @Test func whiteBalanceGoesPartOfTheWayFromTheCameraS() {
        let look = Preset(name: "Warm", capturing: edited, groups: [.whiteBalance])
        let asShot = WhiteBalance(temperature: 5000, tint: 0)
        #expect(look.applied(to: Adjustments(), amount: 0.5, asShot: asShot).whiteBalance == WhiteBalance(temperature: 5500, tint: 2))
        #expect(look.applied(to: Adjustments(), amount: 0, asShot: asShot).whiteBalance == nil)
        // Without knowing what the camera chose, it can only switch.
        #expect(look.applied(to: Adjustments(), amount: 0.4).whiteBalance == nil)
        #expect(look.applied(to: Adjustments(), amount: 0.6).whiteBalance == edited.whiteBalance)
    }

    @Test func decoderAmountsInterpolateWhenBothAreSetElseSwitch() {
        let look = Preset(name: "Detail", capturing: edited, groups: [.detail])
        var current = Adjustments()
        current.sharpness = 20
        let half = look.applied(to: current, amount: 0.5)
        #expect(half.sharpness == 40)
        #expect(half.luminanceNoiseReduction == 25 && look.applied(to: current, amount: 0.4).luminanceNoiseReduction == nil)
    }

    /// A field added to a group later must not be forgotten here: dosed at 75 %, a look that
    /// carries everything moves every field of the document.
    @Test func noFieldIsLeftBehind() throws {
        func document(_ adjustments: Adjustments) throws -> [String: NSObject] {
            try #require(try JSONSerialization.jsonObject(with: adjustments.jsonData()) as? [String: NSObject])
        }
        let look = Preset(name: "All", capturing: edited, groups: Set(AdjustmentGroup.allCases))
        let (neutral, dosed) = (try document(Adjustments()), try document(look.applied(to: Adjustments(), amount: 0.75)))
        for field in try document(edited).keys where field != "version" {
            #expect(dosed[field] != nil && dosed[field] != neutral[field], "\(field) does not follow the amount")
        }
    }

    /// The amount slider has to say what it cannot fade, and only for the look at hand: a
    /// look of light and color has nothing to warn about.
    @Test func alookSaysWhatItSwitchesRatherThanFades() {
        #expect(Preset(name: "Light", capturing: edited, groups: [.light, .hsl]).switchesAtHalf.isEmpty)

        let everything = Preset(name: "All", capturing: edited, groups: Set(AdjustmentGroup.allCases))
        #expect(everything.switchesAtHalf == ["black and white", "the framing", "layers", "spots"])

        // Only what the look actually carries: the same settings, kept as a look of layers.
        #expect(Preset(name: "Local", capturing: edited, groups: [.local]).switchesAtHalf == ["layers"])

        // A look that carries a group without changing anything in it warns about nothing.
        #expect(Preset(name: "Empty", capturing: Adjustments(), groups: Set(AdjustmentGroup.allCases)).switchesAtHalf.isEmpty)
    }

    @Test func whateverTheAmountTheResultIsADocumentTheEngineAccepts() {
        let look = Preset(name: "All", capturing: edited, groups: Set(AdjustmentGroup.allCases))
        for amount in stride(from: 0.0, through: 1.0, by: 0.1) {
            let result = look.applied(to: photo, amount: amount)
            #expect(result.sanitized() == result, "at \(amount)")
        }
    }
}
