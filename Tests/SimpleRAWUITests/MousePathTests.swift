import CoreGraphics
import Testing
@testable import SimpleRAWUI

@Suite struct MousePathTests {
    @Test func aStraightDragPassesThroughBothEnds() {
        let points = MousePath.straight(from: .init(x: 0, y: 0), to: .init(x: 100, y: 50), steps: 4)
        #expect(points.count == 5)
        #expect(points.first == CGPoint(x: 0, y: 0))
        #expect(points.last == CGPoint(x: 100, y: 50))
        #expect(points[2] == CGPoint(x: 50, y: 25))
    }

    /// A press with no movement is still a press: the two ends, and nothing in between.
    @Test func aDragOfNoStepsIsJustItsEnds() {
        let points = MousePath.straight(from: .init(x: 3, y: 4), to: .init(x: 3, y: 4), steps: 0)
        #expect(points == [CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 4)])
    }

    /// Corners are passed once, not twice: a stroke that stops and starts again on the same
    /// point is a different gesture from one that turns.
    @Test func aDragThroughSeveralPlacesKeepsEachCornerOnce() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        let points = MousePath.through(corners, stepsEach: 2)
        #expect(points.count == 5)
        #expect(points.last == CGPoint(x: 10, y: 10))
        #expect(points.filter { $0 == CGPoint(x: 10, y: 0) }.count == 1)
    }

    /// SwiftUI measures from the top left of the window, an `NSEvent` from the bottom left of
    /// the content view. Get this wrong and the script presses somewhere else entirely, which
    /// is exactly the kind of mistake a scripted gesture is there to catch.
    @Test func aPlaceInAViewBecomesAPlaceInTheWindow() {
        let frame = CGRect(x: 100, y: 50, width: 200, height: 20)
        #expect(MousePath.inWindow(frame, at: .init(x: 0.5, y: 0.5), contentHeight: 800) == CGPoint(x: 200, y: 740))
        #expect(MousePath.inWindow(frame, at: .init(x: 0, y: 0), contentHeight: 800) == CGPoint(x: 100, y: 750))
        #expect(MousePath.inWindow(frame, at: .init(x: 1, y: 1), contentHeight: 800) == CGPoint(x: 300, y: 730))
    }
}
