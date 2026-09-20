import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct BrushMaskTests {
    let probe = PixelProbe()
    let extent = CGRect(x: 0, y: 0, width: 300, height: 200)
    /// A horizontal stroke across the picture, a quarter of the way down, 0.05 × 300 = 15 px wide each side.
    let stroke = BrushMask.Stroke(points: [.init(x: 0.1, y: 0.25), .init(x: 0.9, y: 0.25)], radius: 0.05)

    private func value(_ mask: BrushMask, atX x: Double, y: Double, in extent: CGRect? = nil) throws -> Float {
        let extent = extent ?? self.extent
        let image = Mask.brush(mask).image(in: extent)
        let point = NormalizedPoint(x: x, y: y).location(in: extent)
        return try probe.average(of: image, in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)).r
    }

    @Test func anEmptyBrushAffectsNothing() throws {
        #expect(try value(BrushMask(), atX: 0.5, y: 0.5) < 0.01)
        #expect(Mask.brush(BrushMask()).image(in: extent).extent == extent)
    }

    @Test func paintsWhereTheStrokeWent() throws {
        let mask = BrushMask(strokes: [stroke])
        #expect(try value(mask, atX: 0.5, y: 0.25) > 0.95)
        #expect(try value(mask, atX: 0.5, y: 0.75) < 0.01)
        // Beyond the end of the stroke, caps included.
        #expect(try value(mask, atX: 0.99, y: 0.25) < 0.05)
    }

    @Test func theEdgeIsSoft() throws {
        let mask = BrushMask(strokes: [stroke])
        // 15 px is the radius: right on the edge, the mask is partly on.
        let edge = try value(mask, atX: 0.5, y: 0.25 + 15.0 / 200)
        #expect(edge > 0.15 && edge < 0.85)
        #expect(try value(mask, atX: 0.5, y: 0.25 + 30.0 / 200) < 0.02)
    }

    @Test func aWiderBrushCoversMore() throws {
        var wide = stroke
        wide.radius = 0.15
        #expect(try value(BrushMask(strokes: [wide]), atX: 0.5, y: 0.25 + 30.0 / 200) > 0.9)
    }

    @Test func erasingRemovesWhatWasPainted() throws {
        let eraser = BrushMask.Stroke(points: [.init(x: 0.5, y: 0.1), .init(x: 0.5, y: 0.4)], radius: 0.05, isErasing: true)
        let mask = BrushMask(strokes: [stroke, eraser])
        #expect(try value(mask, atX: 0.5, y: 0.25) < 0.05)
        #expect(try value(mask, atX: 0.2, y: 0.25) > 0.95)
    }

    @Test func aClickPaintsADot() throws {
        let dot = BrushMask(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], radius: 0.05)])
        #expect(try value(dot, atX: 0.5, y: 0.5) > 0.9)
        #expect(try value(dot, atX: 0.7, y: 0.5) < 0.01)
    }

    /// The preview and the full-size export must get the same mask.
    @Test func isTheSameAtAnyResolution() throws {
        let mask = BrushMask(strokes: [stroke])
        let large = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for (x, y) in [(0.5, 0.25), (0.5, 0.25 + 15.0 / 200), (0.3, 0.6)] {
            let small = try value(mask, atX: x, y: y)
            let big = try value(mask, atX: x, y: y, in: large)
            #expect(abs(small - big) < 0.08, "at \(x), \(y)")
        }
    }

    @Test func roundTripsThroughJSON() throws {
        let mask = Mask.brush(BrushMask(strokes: [stroke]))
        #expect(try JSONDecoder().decode(Mask.self, from: JSONEncoder().encode(mask)) == mask)
    }
}

/// Painting draws only what is new. Whatever road a raster took, it must be the one a fresh
/// rasterization of the same mask gives, pixel for pixel.
@Suite struct BrushRasterizerTests {
    let size = CGSize(width: 600, height: 400)

    /// Three strokes: a plain one, an eraser crossing it, and a wider one.
    static let strokes: [BrushMask.Stroke] = [
        .init(points: (0...40).map { .init(x: 0.1 + Double($0) * 0.02, y: 0.3 + 0.1 * sin(Double($0) / 5)) }, radius: 0.04),
        .init(points: (0...20).map { .init(x: 0.5 + 0.005 * Double($0), y: 0.05 + Double($0) * 0.03) }, radius: 0.02, isErasing: true),
        .init(points: (0...30).map { .init(x: 0.9 - Double($0) * 0.025, y: 0.7 + 0.05 * cos(Double($0) / 3)) }, radius: 0.07),
    ]

    private func bytes(_ image: CGImage?) throws -> Data {
        try #require(image?.dataProvider?.data) as Data
    }

    @Test func paintingPointByPointGivesTheSamePixelsAsDrawingItAllAtOnce() throws {
        let painted = BrushRasterizer(size: size)
        var mask = BrushMask()
        var points = 0
        for stroke in Self.strokes {
            mask.strokes.append(.init(points: [stroke.points[0]], radius: stroke.radius, isErasing: stroke.isErasing))
            _ = painted.bitmap(for: mask)
            for point in stroke.points.dropFirst() {
                mask.strokes[mask.strokes.count - 1].points.append(point)
                _ = painted.bitmap(for: mask)
            }
            points += stroke.points.count
        }
        #expect(mask == BrushMask(strokes: Self.strokes))
        // Each point was drawn once, and the picture was never started over.
        #expect(painted.fullDraws == 1)
        #expect(painted.pointsDrawn == points)

        let atOnce = BrushRasterizer(size: size)
        #expect(try bytes(painted.bitmap(for: mask)) == bytes(atOnce.bitmap(for: mask)))
        #expect(atOnce.fullDraws == 1 && atOnce.pointsDrawn == points)
    }

    @Test func askingAgainForTheSameMaskDrawsNothing() throws {
        let rasterizer = BrushRasterizer(size: size)
        let mask = BrushMask(strokes: Self.strokes)
        let first = try bytes(rasterizer.bitmap(for: mask))
        let drawn = rasterizer.pointsDrawn
        #expect(try bytes(rasterizer.bitmap(for: mask)) == first)
        #expect(rasterizer.pointsDrawn == drawn)
    }

    /// Undoing a stroke, moving a point, changing a radius: anything that is not "more points
    /// at the end" starts the picture over.
    @Test(arguments: [0, 1, 2, 3])
    func anyOtherChangeRedrawsEverything(change: Int) throws {
        var changed = BrushMask(strokes: Self.strokes)
        switch change {
        case 0: changed.strokes.removeLast()
        case 1: changed.strokes[0].points[3].y += 0.1
        case 2: changed.strokes[2].radius = 0.05
        default: changed.strokes[2].points.removeLast()
        }
        let rasterizer = BrushRasterizer(size: size)
        _ = rasterizer.bitmap(for: BrushMask(strokes: Self.strokes))
        let redrawn = try bytes(rasterizer.bitmap(for: changed))
        #expect(rasterizer.fullDraws == 2)
        #expect(redrawn == (try bytes(BrushRasterizer(size: size).bitmap(for: changed))))
    }

    /// The canvas and the histogram ask for the same mask at two sizes on every frame: one
    /// raster serves both, whatever the rounding of their sizes did to the aspect ratio.
    @Test func thePreviewAndTheHistogramShareOneRaster() {
        let store = BrushRasterStore()
        var mask = BrushMask(strokes: [Self.strokes[0]])
        let (canvas, histogram) = (CGRect(x: 0, y: 0, width: 2300, height: 1533), CGRect(x: 0, y: 0, width: 512, height: 341))
        for point in Self.strokes[2].points {
            mask.strokes[0].points.append(point)
            #expect(mask.image(in: canvas, store: store) != nil)
            #expect(mask.image(in: histogram, store: store) != nil)
        }
        #expect(store.rasterizers.count == 1)
        #expect(store.rasterizers.first?.fullDraws == 1)
    }

    /// A lagging reader (the histogram, a few points behind) must not make the canvas start
    /// its own raster over.
    @Test func anOlderMaskDoesNotClobberTheRasterBeingPainted() {
        let store = BrushRasterStore()
        let extent = CGRect(x: 0, y: 0, width: 600, height: 400)
        var mask = BrushMask(strokes: [Self.strokes[0]])
        let older = mask
        mask.strokes[0].points.append(.init(x: 0.95, y: 0.5))
        _ = mask.image(in: extent, store: store)
        _ = older.image(in: extent, store: store)
        mask.strokes[0].points.append(.init(x: 0.97, y: 0.55))
        _ = mask.image(in: extent, store: store)
        let painting = store.rasterizers.first { $0.pointsDrawn == mask.strokes[0].points.count }
        #expect(painting?.fullDraws == 1)
    }

    /// Another frame altogether (another photo, a portrait one) gets a raster of its own.
    @Test func anotherAspectRatioGetsItsOwnRaster() {
        let store = BrushRasterStore()
        let mask = BrushMask(strokes: Self.strokes)
        _ = mask.image(in: CGRect(x: 0, y: 0, width: 600, height: 400), store: store)
        _ = mask.image(in: CGRect(x: 0, y: 0, width: 400, height: 600), store: store)
        #expect(store.rasterizers.count == 2)
    }
}
