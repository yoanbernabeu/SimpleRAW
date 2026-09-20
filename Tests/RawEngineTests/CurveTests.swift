import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct CurveMathTests {
    @Test func identityMapsEveryLevelToItself() {
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(abs(Curve.identity.value(at: x) - x) < 1e-9)
        }
        #expect(Curve.identity.isIdentity)
    }

    @Test func passesThroughItsControlPoints() {
        let curve = Curve(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.4), .init(x: 0.7, y: 0.65), .init(x: 1, y: 1)])
        for point in curve.points {
            #expect(abs(curve.value(at: point.x) - point.y) < 1e-9)
        }
        #expect(!curve.isIdentity)
    }

    /// A plain cubic spline overshoots between uneven points; tones must never invert.
    @Test func staysMonotonicBetweenMonotonicPoints() {
        let curve = Curve(points: [.init(x: 0, y: 0), .init(x: 0.1, y: 0.5), .init(x: 0.15, y: 0.52), .init(x: 1, y: 1)])
        let samples = curve.lookupTable(size: 512)
        for (previous, next) in zip(samples, samples.dropFirst()) {
            #expect(next >= previous - 1e-6)
        }
    }

    @Test func isFlatBeyondItsEndPoints() {
        let curve = Curve(points: [.init(x: 0.2, y: 0.1), .init(x: 0.8, y: 0.9)])
        #expect(curve.value(at: 0) == 0.1)
        #expect(curve.value(at: 1) == 0.9)
    }

    @Test func outputIsClampedToTheUnitRange() {
        let curve = Curve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 1), .init(x: 1, y: 1)])
        #expect(curve.lookupTable(size: 256).allSatisfy { (0...1).contains($0) })
    }

    @Test func pointsAreKeptSortedWhateverTheInputOrder() {
        let curve = Curve(points: [.init(x: 1, y: 1), .init(x: 0, y: 0), .init(x: 0.5, y: 0.6)])
        #expect(curve.points.map(\.x) == [0, 0.5, 1])
    }
}

@Suite struct CurveEditingTests {
    @Test func insertingReturnsTheIndexOfTheNewPoint() {
        var curve = Curve.identity
        let index = curve.insert(.init(x: 0.5, y: 0.7))
        #expect(index == 1)
        #expect(curve.points.count == 3)
        #expect(abs(curve.value(at: 0.5) - 0.7) < 1e-9)
    }

    @Test func aPointCannotBeDraggedPastItsNeighbours() {
        var curve = Curve(points: [.init(x: 0, y: 0), .init(x: 0.4, y: 0.4), .init(x: 0.6, y: 0.6), .init(x: 1, y: 1)])
        curve.move(at: 1, to: .init(x: 0.9, y: 0.5))
        #expect(curve.points[1].x < curve.points[2].x)
        #expect(curve.points[1].y == 0.5)
    }

    @Test func aPointCannotLeaveTheUnitSquare() {
        var curve = Curve.identity
        let index = curve.insert(.init(x: 0.5, y: 0.5))
        curve.move(at: index, to: .init(x: 0.5, y: 1.8))
        #expect(curve.points[index].y == 1)
    }

    @Test func endPointsCanMoveButNotBeRemoved() {
        var curve = Curve.identity
        curve.move(at: 0, to: .init(x: 0, y: 0.1))
        #expect(curve.points[0] == Curve.Point(x: 0, y: 0.1))
        curve.remove(at: 0)
        #expect(curve.points.count == 2)
    }

    @Test func removingAnInnerPointRestoresTheCurve() {
        var curve = Curve.identity
        let index = curve.insert(.init(x: 0.5, y: 0.8))
        curve.remove(at: index)
        #expect(curve.isIdentity)
    }

    @Test func nearestPointFindsWhatTheUserGrabbed() {
        let curve = Curve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.7), .init(x: 1, y: 1)])
        #expect(curve.indexOfPoint(near: .init(x: 0.52, y: 0.69), within: 0.05) == 1)
        #expect(curve.indexOfPoint(near: .init(x: 0.3, y: 0.1), within: 0.05) == nil)
    }
}

@Suite struct CurvesDocumentTests {
    @Test func curvesRoundTripThroughJSON() throws {
        var adjustments = Adjustments()
        adjustments.curves.rgb.insert(.init(x: 0.5, y: 0.6))
        adjustments.curves.blue.insert(.init(x: 0.25, y: 0.2))
        let decoded = try JSONDecoder().decode(Adjustments.self, from: adjustments.jsonData())
        #expect(decoded == adjustments)
    }

    @Test func aDocumentWithoutCurvesIsNeutral() throws {
        let decoded = try JSONDecoder().decode(Adjustments.self, from: Data(#"{"contrast": 10}"#.utf8))
        #expect(decoded.curves == Curves())
        #expect(decoded.curves.isIdentity)
    }

    @Test func aPresetMayCarryASingleChannel() throws {
        let preset = Data(#"{"curves": {"red": {"points": [{"x": 0, "y": 0.1}, {"x": 1, "y": 1}]}}}"#.utf8)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: preset)
        #expect(decoded.curves.red.points.first?.y == 0.1)
        #expect(decoded.curves.rgb.isIdentity)
    }
}

@Suite struct CurvesStageTests {
    let probe = PixelProbe()
    let stage = CurvesStage()
    /// sRGB 0.5, linearized: curves are drawn on display levels.
    let midGray = PixelProbe.swatch(r: 0.214, g: 0.214, b: 0.214)

    @Test func liftsTheLevelItWasAskedTo() throws {
        var adjustments = Adjustments()
        adjustments.curves.rgb.insert(.init(x: 0.5, y: 0.7))
        let output = try probe.average(of: stage.apply(adjustments, to: midGray))
        // sRGB 0.7, linearized.
        #expect(abs(output.luminance - 0.448) < 0.01)
    }

    @Test func aChannelCurveLeavesTheOtherChannelsAlone() throws {
        var adjustments = Adjustments()
        adjustments.curves.red.insert(.init(x: 0.5, y: 0.8))
        let output = try probe.average(of: stage.apply(adjustments, to: midGray))
        #expect(output.r > 0.4)
        #expect(abs(output.g - 0.214) < 0.005)
        #expect(abs(output.b - 0.214) < 0.005)
    }

    @Test func theMasterCurveAppliesBeforeTheChannelCurves() throws {
        var adjustments = Adjustments()
        // Master sends 0.5 to 0.25; red then sends 0.25 to 0.75.
        adjustments.curves.rgb.insert(.init(x: 0.5, y: 0.25))
        adjustments.curves.red.insert(.init(x: 0.25, y: 0.75))
        let output = try probe.average(of: stage.apply(adjustments, to: midGray))
        // sRGB 0.75 → 0.522 linear, sRGB 0.25 → 0.051 linear.
        #expect(abs(output.r - 0.522) < 0.015)
        #expect(abs(output.g - 0.051) < 0.005)
    }
}

/// A table is built on every frame of a drag: it takes a faster road than evaluating the
/// curve level by level, and must land on exactly the same values.
@Suite struct CurveTableTests {
    /// Points on the table's own grid (a sample falls right on a control point), two of
    /// them as close as editing allows, and a part that goes down.
    static let awkward = Curve(points: [
        .init(x: 0, y: 0.05), .init(x: 341.0 / 1023, y: 0.6), .init(x: 341.0 / 1023 + Curve.minimumGap, y: 0.62),
        .init(x: 0.5, y: 0.3), .init(x: 682.0 / 1023, y: 0.3), .init(x: 0.9, y: 0.95),
    ])

    @Test(arguments: [Curve.identity, awkward, Curve(points: [.init(x: 0.2, y: 0.1), .init(x: 0.8, y: 0.9)])])
    func theTableIsTheCurveEvaluatedLevelByLevel(curve: Curve) {
        for size in [2, 256, 1024] {
            let table = curve.lookupTable(size: size)
            #expect(table.count == size)
            for (index, value) in table.enumerated() {
                #expect(value == Float(curve.value(at: Double(index) / Double(size - 1))), "level \(index) of \(size)")
            }
        }
    }

    /// What the GPU receives: red, green and blue interleaved, each channel curve evaluated
    /// on what the master curve made of the level, even where the master goes down.
    @Test func theStageTableChainsTheMasterIntoEachChannel() {
        var curves = Curves()
        curves.rgb = Self.awkward
        curves.red = Curve(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.75), .init(x: 1, y: 1)])
        curves.blue = Curve(points: [.init(x: 0, y: 0.2), .init(x: 1, y: 0.8)])

        let table = CurvesStage.table(for: curves).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(table.count == CurvesStage.tableSize * 3)
        for level in stride(from: 0, to: CurvesStage.tableSize, by: 7) {
            let master = Double(Float(curves.rgb.value(at: Double(level) / Double(CurvesStage.tableSize - 1))))
            #expect(table[level * 3] == Float(curves.red.value(at: master)))
            #expect(table[level * 3 + 1] == Float(curves.green.value(at: master)))
            #expect(table[level * 3 + 2] == Float(curves.blue.value(at: master)))
        }
    }
}
