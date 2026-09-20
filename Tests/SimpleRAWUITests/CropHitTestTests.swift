import CoreGraphics
import RawEngine
import Testing
@testable import SimpleRAWUI

@Suite struct CropHitTestTests {
    let rect = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test func cornersWinOverEdges() {
        #expect(CropHitTest.target(at: CGPoint(x: 105, y: 96), in: rect) == .corner(.topLeft))
        #expect(CropHitTest.target(at: CGPoint(x: 495, y: 405), in: rect) == .corner(.bottomRight))
    }

    @Test func anEdgeIsGrabbedAlongItsWholeLength() {
        #expect(CropHitTest.target(at: CGPoint(x: 300, y: 104), in: rect) == .edge(.top))
        #expect(CropHitTest.target(at: CGPoint(x: 300, y: 392), in: rect) == .edge(.bottom))
        #expect(CropHitTest.target(at: CGPoint(x: 92, y: 250), in: rect) == .edge(.left))
        #expect(CropHitTest.target(at: CGPoint(x: 508, y: 250), in: rect) == .edge(.right))
    }

    @Test func theMiddleMovesTheCropAndOutsideDoesNothing() {
        #expect(CropHitTest.target(at: CGPoint(x: 300, y: 250), in: rect) == .inside)
        #expect(CropHitTest.target(at: CGPoint(x: 40, y: 40), in: rect) == nil)
        #expect(CropHitTest.target(at: CGPoint(x: 300, y: 60), in: rect) == nil)
    }

    /// On a small crop the handles must not eat the whole rectangle.
    @Test func aSmallCropCanStillBeMoved() {
        let small = CGRect(x: 100, y: 100, width: 60, height: 60)
        #expect(CropHitTest.target(at: CGPoint(x: 130, y: 130), in: small) == .inside)
    }
}
