import Testing
@testable import SimpleRAWUI

@Suite struct SliderGeometryTests {
    let range = -100.0...100.0

    @Test func aPositionOnTheTrackIsAValueRoundedToTheStep() {
        #expect(SliderGeometry.value(atShare: 0.75, range: range, neutral: 0, step: 1) == 50)
        #expect(SliderGeometry.value(atShare: 0.7512, range: range, neutral: 0, step: 1) == 50)
        #expect(SliderGeometry.value(atShare: 0.25, range: 2000...12000, neutral: 5200, step: 50) == 4500)
    }

    @Test func positionsOffTheTrackAreTheEnds() {
        #expect(SliderGeometry.value(atShare: -0.2, range: range, neutral: 0, step: 1) == -100)
        #expect(SliderGeometry.value(atShare: 1.4, range: range, neutral: 0, step: 1) == 100)
    }

    /// "Back to zero" must be easy to hit, even when neutral is not a multiple of the step.
    @Test func closeToNeutralSnapsToIt() {
        #expect(SliderGeometry.value(atShare: 0.505, range: range, neutral: 0, step: 1) == 0)
        #expect(SliderGeometry.value(atShare: 0.3215, range: 2000...12000, neutral: 5213, step: 50) == 5213)
    }

    @Test func aValueHasAPlaceOnTheTrack() {
        #expect(SliderGeometry.share(of: 50, in: range) == 0.75)
        #expect(SliderGeometry.share(of: 500, in: range) == 1)
        #expect(SliderGeometry.share(of: 3, in: 3...3) == 0)
    }

    @Test func arrowKeysMoveByStepsAndStopAtTheEnds() {
        #expect(SliderGeometry.nudged(10, bySteps: 1, range: range, step: 1) == 11)
        #expect(SliderGeometry.nudged(10, bySteps: -10, range: range, step: 1) == 0)
        #expect(SliderGeometry.nudged(95, bySteps: 10, range: range, step: 1) == 100)
        #expect(abs(SliderGeometry.nudged(0.1, bySteps: 1, range: -5...5, step: 0.05) - 0.15) < 1e-9)
    }

    /// With Option held the drag is relative and four times finer.
    @Test func aFineDragMovesAQuarterOfTheDistance() {
        #expect(SliderGeometry.value(from: 20, draggedByShare: 0.1, range: range, step: 1, sensitivity: 0.25) == 25)
        #expect(SliderGeometry.value(from: 98, draggedByShare: 0.5, range: range, step: 1, sensitivity: 0.25) == 100)
    }

    @Test func typedValuesAreReadInEitherNotationAndKeptInRange() {
        #expect(SliderGeometry.parsed("5600", range: 2000...12000) == 5600)
        #expect(SliderGeometry.parsed(" -0,35 ", range: -5...5) == -0.35)
        #expect(SliderGeometry.parsed("+12", range: range) == 12)
        #expect(SliderGeometry.parsed("900", range: range) == 100)
        #expect(SliderGeometry.parsed("warm", range: range) == nil)
        #expect(SliderGeometry.parsed("", range: range) == nil)
    }
}
