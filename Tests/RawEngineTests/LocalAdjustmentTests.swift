import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct MaskMathTests {
    /// Full effect on the start side, none past the end, a smooth ramp in between.
    @Test func aLinearMaskFadesFromStartToEnd() {
        let mask = LinearMask(start: .init(x: 0.5, y: 0.2), end: .init(x: 0.5, y: 0.6))
        #expect(mask.value(at: .init(x: 0.5, y: 0.0), aspect: 1.5) == 1)
        #expect(mask.value(at: .init(x: 0.1, y: 0.2), aspect: 1.5) == 1)
        #expect(abs(mask.value(at: .init(x: 0.9, y: 0.4), aspect: 1.5) - 0.5) < 1e-9)
        #expect(mask.value(at: .init(x: 0.5, y: 0.9), aspect: 1.5) == 0)
    }

    /// Drawn on a 3:2 picture, a diagonal gradient must stay perpendicular to its axis on
    /// screen, not in normalized space.
    @Test func aLinearMaskIsMeasuredInPixelsNotInFractions() {
        let mask = LinearMask(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1))
        let onAxis = mask.value(at: .init(x: 0.5, y: 0.5), aspect: 3)
        #expect(abs(onAxis - 0.5) < 1e-9)
        // Same distance along the axis, measured in pixels of a 3:1 picture.
        let offAxis = mask.value(at: .init(x: 0.5 + 0.1 / 3, y: 0.5 - 0.1 * 3 / 3), aspect: 3)
        #expect(abs(offAxis - 0.5) < 0.05)
    }

    @Test func aRadialMaskIsFullInsideAndFadesToItsEdge() {
        let mask = RadialMask(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.4, feather: 0.5, isInverted: false)
        #expect(mask.value(at: .init(x: 0.5, y: 0.5)) == 1)
        #expect(mask.value(at: .init(x: 0.5 + 0.09, y: 0.5)) == 1)
        #expect(abs(mask.value(at: .init(x: 0.5 + 0.15, y: 0.5)) - 0.5) < 1e-9)
        #expect(mask.value(at: .init(x: 0.5 + 0.21, y: 0.5)) == 0)
        // An ellipse: twice as far along y.
        #expect(abs(mask.value(at: .init(x: 0.5, y: 0.5 + 0.3)) - 0.5) < 1e-9)
    }

    @Test func anInvertedRadialMaskAffectsTheOutside() {
        let mask = RadialMask(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2, feather: 0.5, isInverted: true)
        #expect(mask.value(at: .init(x: 0.5, y: 0.5)) == 0)
        #expect(mask.value(at: .init(x: 0.95, y: 0.5)) == 1)
    }
}

@Suite struct MaskRenderingTests {
    let probe = PixelProbe()
    let extent = CGRect(x: 0, y: 0, width: 300, height: 200)

    /// The rendered mask must agree with the math, top-left origin included.
    @Test func aRenderedLinearMaskMatchesItsMath() throws {
        let mask = LinearMask(start: .init(x: 0.5, y: 0.2), end: .init(x: 0.5, y: 0.6))
        let image = Mask.linear(mask).image(in: extent)
        // y = 0.1 from the top is y = 180 in Core Image coordinates.
        #expect(try sample(image, x: 150, y: 180) > 0.97)
        #expect(abs(try sample(image, x: 150, y: 120) - 0.5) < 0.04)
        #expect(try sample(image, x: 150, y: 20) < 0.03)
    }

    @Test func aRenderedRadialMaskMatchesItsMath() throws {
        let mask = RadialMask(center: .init(x: 0.25, y: 0.25), radiusX: 0.2, radiusY: 0.3, feather: 0.5, isInverted: false)
        let image = Mask.radial(mask).image(in: extent)
        #expect(try sample(image, x: 75, y: 150) > 0.97)
        #expect(abs(try sample(image, x: 75 + 45, y: 150) - 0.5) < 0.05)
        #expect(try sample(image, x: 250, y: 50) < 0.03)
        #expect(image.extent == extent)
    }

    private func sample(_ image: CIImage, x: CGFloat, y: CGFloat) throws -> Float {
        try probe.average(of: image, in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)).r
    }
}

@Suite struct LocalAdjustmentsStageTests {
    let probe = PixelProbe()
    let stage = LocalAdjustmentsStage()
    let gray = PixelProbe.swatch(r: 0.2, g: 0.2, b: 0.2, size: CGSize(width: 300, height: 200))

    private func local(_ edit: (inout LocalSettings) -> Void) -> LocalAdjustment {
        var settings = LocalSettings()
        edit(&settings)
        // Top half fully affected, bottom half untouched, a short ramp in the middle.
        return LocalAdjustment(mask: .linear(LinearMask(start: .init(x: 0.5, y: 0.45), end: .init(x: 0.5, y: 0.55))), settings: settings)
    }

    private func top(_ image: CIImage) throws -> PixelProbe.Pixel {
        try probe.average(of: image, in: CGRect(x: 100, y: 150, width: 100, height: 30))
    }

    private func bottom(_ image: CIImage) throws -> PixelProbe.Pixel {
        try probe.average(of: image, in: CGRect(x: 100, y: 20, width: 100, height: 30))
    }

    @Test func exposureAppliesInsideTheMaskOnly() throws {
        var adjustments = Adjustments()
        adjustments.locals = [local { $0.exposure = 1 }]
        let output = stage.apply(adjustments, to: gray)
        #expect(abs(try top(output).luminance - 0.4) < 0.01)
        #expect(abs(try bottom(output).luminance - 0.2) < 0.005)
    }

    @Test func saturationAppliesInsideTheMaskOnly() throws {
        let orange = PixelProbe.swatch(r: 0.5, g: 0.3, b: 0.1, size: CGSize(width: 300, height: 200))
        var adjustments = Adjustments()
        adjustments.locals = [local { $0.saturation = -100 }]
        let output = stage.apply(adjustments, to: orange)
        #expect(try top(output).chroma < 0.02)
        #expect(try bottom(output).chroma > 0.35)
    }

    @Test func warmingShiftsTowardRed() throws {
        var adjustments = Adjustments()
        adjustments.locals = [local { $0.temperature = 60 }]
        let output = stage.apply(adjustments, to: gray)
        #expect(try top(output).r > top(output).b * 1.1)
        #expect(abs(try bottom(output).r - bottom(output).b) < 0.005)
    }

    /// A picture with a vertical edge across both halves: dark on the left, light on the right.
    private var edged: CIImage {
        PixelProbe.swatch(r: 0.5, g: 0.5, b: 0.5, size: CGSize(width: 150, height: 200))
            .transformed(by: CGAffineTransform(translationX: 150, y: 0))
            .composited(over: PixelProbe.swatch(r: 0.1, g: 0.1, b: 0.1, size: CGSize(width: 300, height: 200)))
    }

    /// Contrast across the edge, just on each side of it, at a given height.
    private func edgeContrast(_ image: CIImage, y: CGFloat) throws -> Float {
        let light = try probe.average(of: image, in: CGRect(x: 152, y: y, width: 4, height: 30)).luminance
        let dark = try probe.average(of: image, in: CGRect(x: 144, y: y, width: 4, height: 30)).luminance
        return light - dark
    }

    /// A look is worked on with a little clarity; a local slider must feel like the global one.
    @Test func clarityAddsPresenceInsideTheMaskOnly() throws {
        MemoryFuse.arm()
        var adjustments = Adjustments()
        adjustments.locals = [local { $0.clarity = 80 }]
        let output = stage.apply(adjustments, to: edged)
        #expect(try edgeContrast(output, y: 150) > edgeContrast(edged, y: 150) + 0.02)
        #expect(abs(try edgeContrast(output, y: 20) - edgeContrast(edged, y: 20)) < 0.003)

        var global = Adjustments()
        global.clarity = 80
        let everywhere = LocalContrastStage().apply(global, to: edged)
        #expect(abs(try edgeContrast(output, y: 150) - edgeContrast(everywhere, y: 150)) < 0.003)
    }

    /// A sky is worked on with local dehaze: blacks come back down, inside the mask only.
    @Test func dehazeCutsTheVeilInsideTheMaskOnly() throws {
        MemoryFuse.arm()
        var adjustments = Adjustments()
        adjustments.locals = [local { $0.dehaze = 80 }]
        let output = stage.apply(adjustments, to: gray)
        #expect(try top(output).luminance < 0.2 - 0.01)
        #expect(abs(try bottom(output).luminance - 0.2) < 0.002)

        adjustments.locals = [local { $0.dehaze = -80 }]
        #expect(try top(stage.apply(adjustments, to: gray)).luminance > 0.2 + 0.01)
    }

    @Test func clarityAndDehazeArePartOfTheDocument() throws {
        let layer = #"{"id": "7E57AB1E-0000-4000-8000-0000000000B1", "mask": {"brush": {"strokes": []}}, "settings": {"clarity": 30, "dehaze": -1e308}}"#
        let settings = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"locals": [\#(layer)]}"#.utf8)).locals[0].settings
        #expect(settings.clarity == 30 && settings.dehaze == -100 && settings.exposure == 0)
        #expect(!settings.isNeutral)
        #expect(try JSONDecoder().decode(LocalSettings.self, from: JSONEncoder().encode(settings)) == settings)
        // Layers saved before the two sliders existed.
        #expect(try JSONDecoder().decode(LocalSettings.self, from: Data(#"{"exposure": 1}"#.utf8)).clarity == 0)
    }

    @Test func localsStack() throws {
        var adjustments = Adjustments()
        adjustments.locals = [local { $0.exposure = 1 }, local { $0.exposure = 1 }]
        #expect(abs(try top(stage.apply(adjustments, to: gray)).luminance - 0.8) < 0.03)
    }

    @Test func aLocalWithNeutralSettingsCostsNothing() {
        var adjustments = Adjustments()
        adjustments.locals = [local { _ in }]
        #expect(stage.apply(adjustments, to: gray) === gray)
    }
}

@Suite struct LocalDocumentTests {
    @Test func localsRoundTripThroughJSON() throws {
        var adjustments = Adjustments()
        var settings = LocalSettings()
        settings.exposure = 0.7
        adjustments.locals = [
            LocalAdjustment(mask: .linear(LinearMask(start: .init(x: 0.1, y: 0.2), end: .init(x: 0.3, y: 0.4))), settings: settings),
            LocalAdjustment(mask: .radial(RadialMask(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.3, feather: 0.4, isInverted: true)), settings: settings),
        ]
        let decoded = try JSONDecoder().decode(Adjustments.self, from: adjustments.jsonData())
        #expect(decoded == adjustments)
    }

    @Test func aDocumentWithoutLocalsHasNone() throws {
        let decoded = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"contrast": 10}"#.utf8))
        #expect(decoded.locals.isEmpty)
    }
}
