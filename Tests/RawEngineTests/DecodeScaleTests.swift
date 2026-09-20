import CoreGraphics
import Testing
@testable import RawEngine

/// Which scale the preview is actually decoded at.
///
/// The scale follows the size of what is shown, so a crop, a straightening or a keystone
/// correction changes it — and changing it decodes the RAW again, forty milliseconds, in the
/// middle of a drag. What a gesture needs is a scale that holds still while it runs.
@Suite struct DecodeScaleTests {
    @Test func theFirstScaleIsTheOneAskedFor() {
        #expect(PreviewScale.held(nil, wanting: 0.4, isSettled: false) == 0.4)
    }

    /// The whole point: a frame that changes size under a gesture keeps the decode it has.
    @Test func aGestureKeepsTheScaleItStartedWith() {
        #expect(PreviewScale.held(0.4, wanting: 0.42, isSettled: false) == 0.4)
        #expect(PreviewScale.held(0.4, wanting: 0.36, isSettled: false) == 0.4)
    }

    /// Held too far, the preview is either visibly soft or decoded much larger than the view
    /// can show. Past a quarter either way, the re-decode is worth its forty milliseconds —
    /// measured at a half too, which decodes less often for exactly the same timings, so the
    /// tighter one is kept: it costs nothing and keeps the preview sharper.
    @Test func aScaleHeldTooFarIsGivenUp() {
        #expect(PreviewScale.held(0.4, wanting: 0.6, isSettled: false) == 0.6)
        #expect(PreviewScale.held(0.4, wanting: 0.2, isSettled: false) == 0.2)
        #expect(PreviewScale.held(0.4, wanting: 0.45, isSettled: false) == 0.4)
    }

    /// Once the gesture is over, the right scale is taken up: what is left on screen is the
    /// picture at the resolution it deserves.
    @Test func whatIsAskedForIsTakenUpOnceEditsSettle() {
        #expect(PreviewScale.held(0.4, wanting: 0.42, isSettled: true) == 0.42)
    }
}
