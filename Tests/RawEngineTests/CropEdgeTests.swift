import Testing
@testable import RawEngine

/// Dragging an edge of the crop, not only its corners.
@Suite struct CropEdgeTests {
    let crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)

    @Test func aFreeEdgeMovesAlone() {
        #expect(crop.resized(dragging: .right, to: 0.9, aspect: nil) == CropRect(x: 0.2, y: 0.2, width: 0.7, height: 0.6))
        let top = crop.resized(dragging: .top, to: 0.1, aspect: nil)
        #expect(abs(top.y - 0.1) < 1e-9 && abs(top.height - 0.7) < 1e-9 && top.width == 0.6)
    }

    @Test func anEdgeStopsAtTheFrameAndAtTheSmallestCrop() {
        #expect(crop.resized(dragging: .left, to: -0.5, aspect: nil).x == 0)
        let squeezed = crop.resized(dragging: .bottom, to: 0.0, aspect: nil)
        #expect(squeezed.height == CropRect.minimumSide && squeezed.y == 0.2)
    }

    /// With a locked ratio, the other dimension follows, around the middle of the crop.
    @Test func aLockedRatioIsKeptAroundTheMiddle() {
        let wider = crop.resized(dragging: .right, to: 0.7, aspect: 1)
        #expect(abs(wider.width - 0.5) < 1e-9 && abs(wider.height - 0.5) < 1e-9)
        #expect(abs(wider.y + wider.height / 2 - 0.5) < 1e-9, "still centered on the same line")
    }

    @Test func aLockedRatioNeverLeavesTheFrame() {
        let offCenter = CropRect(x: 0.1, y: 0.0, width: 0.3, height: 0.3)
        let grown = offCenter.resized(dragging: .right, to: 1.0, aspect: 1)
        #expect(grown.y >= 0 && grown.maxY <= 1 + 1e-9 && grown.maxX <= 1 + 1e-9)
        #expect(abs(grown.width - grown.height) < 1e-9)
    }
}
