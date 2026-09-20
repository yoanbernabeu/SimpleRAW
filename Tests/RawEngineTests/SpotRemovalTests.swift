import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct SpotRemovalStageTests {
    let probe = PixelProbe()
    let stage = SpotRemovalStage()
    /// A gray 300 × 200 frame with a white speck of dust in its center, and a blue patch on
    /// the left, to tell where pixels come from.
    let dusty: CIImage = {
        let size = CGSize(width: 300, height: 200)
        let speck = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 10, height: 10))
            .transformed(by: CGAffineTransform(translationX: 145, y: 95))
        let patch = PixelProbe.swatch(r: 0, g: 0, b: 1, size: CGSize(width: 30, height: 30))
            .transformed(by: CGAffineTransform(translationX: 45, y: 85))
        return speck.composited(over: patch).composited(over: PixelProbe.swatch(r: 0.2, g: 0.2, b: 0.2, size: size))
    }()

    private func center(_ image: CIImage) throws -> PixelProbe.Pixel {
        try probe.average(of: image, in: CGRect(x: 146, y: 96, width: 8, height: 8))
    }

    private func adjustments(_ spots: Spot...) -> Adjustments {
        var adjustments = Adjustments()
        adjustments.spots = spots
        return adjustments
    }

    @Test func theSpeckIsReplacedByCleanPixels() throws {
        #expect(try center(dusty).luminance > 0.9)
        let spot = Spot(target: .init(x: 0.5, y: 0.5), source: .init(x: 0.75, y: 0.5), radius: 0.04)
        let output = stage.apply(adjustments(spot), to: dusty)
        #expect(abs(try center(output).luminance - 0.2) < 0.01)
        #expect(output.extent == dusty.extent)
    }

    @Test func pixelsComeFromTheSource() throws {
        // Source on the blue patch (x = 60 of 300, y = 100 of 200).
        let spot = Spot(target: .init(x: 0.5, y: 0.5), source: .init(x: 0.2, y: 0.5), radius: 0.04)
        let healed = try center(stage.apply(adjustments(spot), to: dusty))
        #expect(healed.b > 0.9 && healed.r < 0.1)
    }

    @Test func nothingChangesAwayFromTheTarget() throws {
        let spot = Spot(target: .init(x: 0.5, y: 0.5), source: .init(x: 0.75, y: 0.5), radius: 0.04)
        let output = stage.apply(adjustments(spot), to: dusty)
        let patch = try probe.average(of: output, in: CGRect(x: 50, y: 90, width: 20, height: 20))
        #expect(patch.b > 0.95)
    }

    /// Round on screen whatever the shape of the picture: the radius is a share of the long edge.
    @Test func theSpotIsACircleInPixels() throws {
        // Blue on the left, gray on the right: a source large enough to fill the whole disc.
        let halves = PixelProbe.swatch(r: 0, g: 0, b: 1, size: CGSize(width: 140, height: 200))
            .composited(over: PixelProbe.swatch(r: 0.2, g: 0.2, b: 0.2, size: CGSize(width: 300, height: 200)))
        let spot = Spot(target: .init(x: 0.75, y: 0.5), source: .init(x: 0.25, y: 0.5), radius: 0.1, feather: 0)
        let output = stage.apply(adjustments(spot), to: halves)
        // 0.1 × 300 = 30 px around (225, 100): 24 px away is inside, horizontally and
        // vertically alike; 36 px away is outside.
        #expect(try probe.average(of: output, in: CGRect(x: 225 + 23, y: 99, width: 2, height: 2)).b > 0.9)
        #expect(try probe.average(of: output, in: CGRect(x: 224, y: 100 + 23, width: 2, height: 2)).b > 0.9)
        #expect(try probe.average(of: output, in: CGRect(x: 224, y: 100 + 35, width: 2, height: 2)).b < 0.3)
        #expect(try probe.average(of: output, in: CGRect(x: 225 + 35, y: 99, width: 2, height: 2)).b < 0.3)
    }

    @Test func spotsRoundTripThroughJSON() throws {
        let document = adjustments(Spot(target: .init(x: 0.1, y: 0.2), source: .init(x: 0.3, y: 0.4), radius: 0.02, feather: 0.3))
        #expect(try JSONDecoder().decode(Adjustments.self, from: document.jsonData()) == document)
    }

    @Test func runsBeforeToneSoThatEveryOtherStageSeesCleanPixels() {
        let stages = DevelopPipeline.standard.stages
        let spots = stages.firstIndex { $0 is SpotRemovalStage }
        let tone = stages.firstIndex { $0 is HighlightsShadowsStage }
        #expect(spots != nil && tone != nil && spots! < tone!)
    }
}

/// A power line, a scratch, a stray branch: a line, not a point. Chasing one with circles
/// leaves a chain of half-covered lumps, so a spot can carry the line drawn along it.
@Suite struct HealingLineTests {
    let probe = PixelProbe()
    let stage = SpotRemovalStage()

    /// A grey 400 × 200 frame with a thin dark wire running across it at mid-height, and a
    /// clean band of grey below to heal from.
    let wired: CIImage = {
        let size = CGSize(width: 400, height: 200)
        let wire = PixelProbe.swatch(r: 0, g: 0, b: 0, size: CGSize(width: 240, height: 3))
            .transformed(by: CGAffineTransform(translationX: 80, y: 120))
        return wire.composited(over: PixelProbe.swatch(r: 0.4, g: 0.4, b: 0.4, size: size))
    }()

    /// Along the wire, in normalized coordinates with the origin at the top left.
    private func alongTheWire() -> Spot {
        let y = 1 - (121.5 / 200)
        let points = stride(from: 0.25, through: 0.75, by: 0.05).map { NormalizedPoint(x: $0, y: y) }
        return Spot(
            target: points[0], source: NormalizedPoint(x: points[0].x, y: y + 0.2),
            radius: 0.02, path: Array(points.dropFirst())
        )
    }

    private func adjustments(_ spot: Spot) -> Adjustments {
        var adjustments = Adjustments()
        adjustments.spots = [spot]
        return adjustments
    }

    @Test func aLineIsHealedAlongItsWholeLength() throws {
        // The wire is there to begin with, from one end to the other.
        for x in [110.0, 200, 290] {
            #expect(try probe.average(of: wired, in: CGRect(x: x, y: 120, width: 4, height: 3)).luminance < 0.1, "no wire at \(x)")
        }
        let output = stage.apply(adjustments(alongTheWire()), to: wired)
        #expect(output.extent == wired.extent)
        for x in [110.0, 200, 290] {
            let pixel = try probe.average(of: output, in: CGRect(x: x, y: 120, width: 4, height: 3))
            #expect(abs(pixel.luminance - 0.4) < 0.05, "the wire is still there at \(x): \(pixel)")
        }
    }

    /// The offset is the same from one end of the line to the other: what is copied stays a
    /// strip of the picture rather than a row of patches.
    @Test func theWholeLineIsHealedWithOneOffset() {
        let spot = alongTheWire()
        #expect(spot.isLine && spot.points.count == 11)
        #expect(abs(spot.offset.y - 0.2) < 1e-9 && abs(spot.offset.x) < 1e-9)
    }

    /// A spot stays a spot: one point, one soft disc, exactly as before.
    @Test func aSpotWithNoLineIsStillADisc() {
        let spot = Spot(target: .init(x: 0.5, y: 0.5), source: .init(x: 0.75, y: 0.5), radius: 0.04)
        #expect(!spot.isLine && spot.points.count == 1)
        if case .radial = SpotRemovalStage.mask(of: spot, in: CGRect(x: 0, y: 0, width: 300, height: 200)) {} else {
            Issue.record("a spot must still be drawn as a disc")
        }
    }

    /// Documents written before a spot could be a line still open, as one point.
    @Test func aSpotSavedBeforeLinesExistedStillOpens() throws {
        let json = #"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","target":{"x":0.5,"y":0.5},"source":{"x":0.6,"y":0.5},"radius":0.02}"#
        let spot = try JSONDecoder().decode(Spot.self, from: Data(json.utf8))
        #expect(!spot.isLine && spot.feather == 0.4 && spot.radius == 0.02)
    }
}
