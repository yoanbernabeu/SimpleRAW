import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct BlackAndWhiteMathTests {
    let red = SIMD3<Float>(0.8, 0.15, 0.15)
    let blue = SIMD3<Float>(0.15, 0.15, 0.8)

    private func gray(_ color: SIMD3<Float>, _ edit: (inout BlackAndWhite) -> Void = { _ in }) -> SIMD3<Float> {
        var settings = BlackAndWhite()
        settings.isEnabled = true
        edit(&settings)
        return BlackAndWhiteTransform(settings).apply(to: color)
    }

    @Test func offChangesNothing() {
        #expect(BlackAndWhiteTransform(BlackAndWhite()).apply(to: red) == red)
    }

    @Test func onGivesANeutralGrayOfTheSameBrightness() {
        let result = gray(red)
        #expect(result.x == result.y && result.y == result.z)
        #expect(abs(result.x - (0.2126 * 0.8 + 0.7152 * 0.15 + 0.0722 * 0.15)) < 0.001)
    }

    /// The point of a mixer: decide how bright each color comes out, like a filter on the lens.
    @Test func aChannelBrightensItsOwnColorOnly() {
        #expect(gray(red) { $0.red = 100 }.x > gray(red).x + 0.05)
        #expect(abs(gray(blue) { $0.red = 100 }.x - gray(blue).x) < 0.005)
        #expect(gray(blue) { $0.blue = -100 }.x < gray(blue).x - 0.02)
    }

    @Test func graysAreNeverAffectedByTheMix() {
        let neutral = SIMD3<Float>(0.4, 0.4, 0.4)
        #expect(abs(gray(neutral) { $0.red = 100; $0.green = -100; $0.blue = 100 }.x - 0.4) < 0.001)
    }

    /// Orange is the channel of skin: it moves what sits between red and yellow, and nothing else.
    @Test func orangeBrightensSkinAndLeavesItsNeighboursAlone() {
        let skin = SIMD3<Float>(0.8, 0.45, 0.1)      // hue 30°
        let yellow = SIMD3<Float>(0.8, 0.8, 0.1)     // hue 60°
        let pureRed = SIMD3<Float>(0.8, 0.1, 0.1)    // hue 0°
        #expect(gray(skin) { $0.orange = 60 }.x > gray(skin).x + 0.05)
        #expect(gray(skin) { $0.orange = -60 }.x < gray(skin).x - 0.05)
        for color in [yellow, pureRed, blue] {
            #expect(gray(color) { $0.orange = 100 } == gray(color), "\(color)")
        }
        // Halfway to red, half the effect.
        let reddish = SIMD3<Float>(0.8, 0.275, 0.1)  // hue 15°
        let (full, half) = (gray(skin) { $0.orange = 60 }.x / gray(skin).x, gray(reddish) { $0.orange = 60 }.x / gray(reddish).x)
        #expect(half > 1.01 && half < full)
    }

    /// Pictures edited before the channel existed come out as they did: orange adds to what
    /// red and yellow already give a skin tone, it does not replace it.
    @Test func withoutOrangeSkinStillFollowsRedAndYellow() {
        let skin = SIMD3<Float>(0.8, 0.45, 0.1)
        let lifted = gray(skin) { $0.red = 40; $0.yellow = 40 }
        #expect(lifted.x > gray(skin).x + 0.02)
        #expect(gray(skin) { $0.red = 40; $0.yellow = 40; $0.orange = 0 } == lifted)
    }

    @Test func aHueBetweenTwoChannelsFollowsBoth() {
        let orange = SIMD3<Float>(0.8, 0.45, 0.1)
        let base = gray(orange).x
        #expect(gray(orange) { $0.red = 100 }.x > base && gray(orange) { $0.yellow = 100 }.x > base)
    }
}

@Suite struct BlackAndWhiteStageTests {
    let probe = PixelProbe()

    @Test func turnsAPictureGrayAndHonorsTheMix() throws {
        let swatch = PixelProbe.swatch(r: 0.6, g: 0.03, b: 0.03)
        var adjustments = Adjustments()
        adjustments.blackAndWhite.isEnabled = true
        let plain = try probe.average(of: BlackAndWhiteStage().apply(adjustments, to: swatch))
        #expect(plain.chroma < 0.01)
        adjustments.blackAndWhite.red = 100
        #expect(try probe.average(of: BlackAndWhiteStage().apply(adjustments, to: swatch)).luminance > plain.luminance)
    }

    @Test func roundTripsAndBelongsToTheColorGroup() throws {
        var adjustments = Adjustments()
        adjustments.blackAndWhite.isEnabled = true
        adjustments.blackAndWhite.yellow = 40
        #expect(try JSONDecoder().decode(Adjustments.self, from: adjustments.jsonData()) == adjustments)
        var target = Adjustments()
        target.apply(adjustments, groups: [.color])
        #expect(target.blackAndWhite == adjustments.blackAndWhite)
    }

    /// The sliders must not make a document look edited while black and white is off.
    @Test func orangeIsPartOfTheDocument() throws {
        let decoded = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"blackAndWhite": {"isEnabled": true, "orange": 35}}"#.utf8))
        #expect(decoded.blackAndWhite.orange == 35 && decoded.blackAndWhite.red == 0)
        #expect(try JSONDecoder().decode(Adjustments.self, from: decoded.jsonData()) == decoded)
        let hostile = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"blackAndWhite": {"orange": -1e308}}"#.utf8))
        #expect(hostile.blackAndWhite.orange == -100)
        // Documents written before it existed.
        #expect(try JSONDecoder().decode(BlackAndWhite.self, from: Data(#"{"isEnabled": true, "red": 20}"#.utf8)).orange == 0)
    }

    @Test func aMixWithoutTheSwitchIsNeutral() {
        var adjustments = Adjustments()
        adjustments.blackAndWhite.red = 50
        adjustments.blackAndWhite.red = 0
        #expect(adjustments == Adjustments())
    }
}
