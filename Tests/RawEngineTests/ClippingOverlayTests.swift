import CoreImage
import Testing
import TestSupport
@testable import RawEngine

/// Where the picture is burnt out or blocked up, shown on the picture itself.
@Suite struct ClippingOverlayTests {
    let probe = PixelProbe()

    private func marked(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> PixelProbe.Pixel {
        try probe.average(of: ClippingOverlay.apply(to: PixelProbe.swatch(r: r, g: g, b: b)))
    }

    @Test func burntHighlightsTurnRed() throws {
        let pixel = try marked(1, 1, 1)
        #expect(pixel.r > 0.8 && pixel.g < 0.2 && pixel.b < 0.2)
    }

    @Test func oneBurntChannelIsEnough() throws {
        let pixel = try marked(1, 0.6, 0.5)
        #expect(pixel.r > 0.8 && pixel.g < 0.2)
    }

    @Test func blockedShadowsTurnBlue() throws {
        let pixel = try marked(0, 0, 0)
        #expect(pixel.b > 0.8 && pixel.r < 0.2 && pixel.g < 0.2)
    }

    @Test(arguments: [0.02, 0.2, 0.6, 0.9])
    func everythingInBetweenIsLeftAlone(level: Double) throws {
        let pixel = try marked(level, level, level)
        #expect(abs(pixel.r - Float(level)) < 0.01 && abs(pixel.b - Float(level)) < 0.01)
    }

    /// Values above display white (a RAW file has them) are clipped too.
    @Test func valuesBeyondWhiteCountAsBurnt() throws {
        #expect(try marked(1.8, 1.8, 1.8).g < 0.2)
    }
}
