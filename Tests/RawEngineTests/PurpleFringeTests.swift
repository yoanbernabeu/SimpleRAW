import Testing
@testable import RawEngine

/// The violet halo a lens leaves along a hard edge against a bright sky — a branch against
/// cloud, a railing against water. It is a colour, so what takes it out is a colour transform;
/// it only ever sits on an edge, which is what keeps the transform off everything else.
///
/// The pure part is tested here: which colours are counted as a fringe, and what is left of
/// one. Where the edges are is the stage's business, and `PurpleFringeStageTests` measures
/// that on a swatch.
@Suite struct PurpleFringeTests {
    @Test func nothingHappensAtZero() {
        let fringe = PurpleFringe(amount: 0)
        #expect(fringe.isNeutral)
        let violet = SIMD3<Float>(0.5, 0.2, 0.9)
        #expect(fringe.corrected(violet) == violet)
    }

    /// Violet and magenta go grey. Their brightness is left alone: what is wrong with a fringe
    /// is its colour, and a dark line where a bright one was is a worse fault than the fringe.
    @Test func violetLosesItsColourAndKeepsItsBrightness() {
        let fringe = PurpleFringe(amount: 100)
        let violet = SIMD3<Float>(0.5, 0.2, 0.9)
        let corrected = fringe.corrected(violet)
        let spread = { (c: SIMD3<Float>) in c.max() - c.min() }
        #expect(spread(corrected) < spread(violet) / 4)
        #expect(abs(PurpleFringe.luminance(corrected) - PurpleFringe.luminance(violet)) < 0.02)
    }

    /// A sky, a leaf and a face are not fringes. This is the whole reason for a narrow band
    /// rather than the colour mixer, which has none between blue and magenta.
    @Test func everythingElseIsLeftAlone() {
        let fringe = PurpleFringe(amount: 100)
        for colour in [
            SIMD3<Float>(0.35, 0.55, 0.9),  // sky
            SIMD3<Float>(0.3, 0.6, 0.25),  // leaf
            SIMD3<Float>(0.85, 0.65, 0.55),  // skin
            SIMD3<Float>(0.9, 0.2, 0.25),  // a red coat
        ] {
            #expect(fringe.corrected(colour) == colour, "\(colour) was treated as a fringe")
        }
    }

    /// Halfway takes half of it: a slider that only has an end is a switch.
    @Test func theSliderIsAMeasureOfHowMuchIsTaken() {
        let violet = SIMD3<Float>(0.5, 0.2, 0.9)
        let spread = { (c: SIMD3<Float>) in c.max() - c.min() }
        let half = spread(PurpleFringe(amount: 50).corrected(violet))
        #expect(half < spread(violet))
        #expect(half > spread(PurpleFringe(amount: 100).corrected(violet)))
    }

    /// Grey has no hue to be in a band, and asking for one is how a divide by zero gets in.
    @Test func greyIsNotAFringe() {
        let grey = SIMD3<Float>(0.5, 0.5, 0.5)
        #expect(PurpleFringe(amount: 100).corrected(grey) == grey)
    }
}
