import CoreGraphics
import Foundation
import Testing
@testable import RawEngine

/// Straightening by drawing a line along something that ought to be level.
@Suite struct LevelToolTests {
    /// Points as a view reports them: y down.
    private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double? {
        LevelTool.straightening(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2))
    }

    @Test func aLineAlreadyLevelAsksForNothing() throws {
        #expect(try #require(line(0, 100, 400, 100)) == 0)
    }

    /// A horizon running downhill to the right is put back up: the picture turns the other way.
    @Test func aHorizonThatFallsToTheRightTurnsThePictureBack() throws {
        // 100 px along, 100 px down: 45° below level.
        let degrees = try #require(line(0, 0, 100, 100))
        #expect(abs(degrees - -45) < 1e-9)
    }

    @Test func aHorizonThatRisesToTheRightTurnsThePictureForward() throws {
        let degrees = try #require(line(0, 100, 200, 100 - 200 * tan(10 * .pi / 180)))
        #expect(abs(degrees - 10) < 1e-6)
    }

    /// Drawn right to left or left to right, it is the same line.
    @Test func theDirectionTheLineIsDrawnInDoesNotMatter() throws {
        let forward = try #require(line(0, 100, 300, 70))
        let backward = try #require(line(300, 70, 0, 100))
        #expect(abs(forward - backward) < 1e-9)
    }

    /// The edge of a door, a lamp post, the corner of a building: steeper than 45°, so it is
    /// an upright, and it is brought to the vertical rather than laid down.
    @Test func aLineSteeperThanFortyFiveIsTakenForAnUpright() throws {
        // Up and slightly to the right: 8° off the vertical.
        let off = 8.0
        let degrees = try #require(line(100, 300, 100 + 300 * tan(off * .pi / 180), 0))
        #expect(abs(degrees - -off) < 1e-6)
        // And the other way: leaning the other side.
        let other = try #require(line(100, 300, 100 - 300 * tan(off * .pi / 180), 0))
        #expect(abs(other - off) < 1e-6)
    }

    /// A click is not a direction.
    @Test func aLineTooShortSaysNothing() {
        #expect(line(100, 100, 104, 103) == nil)
        #expect(line(100, 100, 100, 100) == nil)
    }

    /// The line is drawn on the picture as it stands, so what it asks for adds to what is
    /// already there — and stays inside what the slider can say.
    @Test func whatIsDrawnAddsToWhatIsAlreadyThere() {
        #expect(LevelTool.straighten(3, by: -1.5) == 1.5)
        #expect(LevelTool.straighten(44, by: 10) == 45)
        #expect(LevelTool.straighten(-44, by: -10) == -45)
    }
}
