import CoreImage
import Testing
import TestSupport
@testable import RawEngine

/// Where the wash lands. The colour rule is `PurpleFringeTests`; this is the other half, and
/// the one that matters to a photographer: a violet flower must come out of it violet, and a
/// halo along a branch must not.
@Suite struct PurpleFringeStageTests {
    /// A violet band down the middle of a black field: two hard edges, and a wide middle that
    /// is nowhere near one.
    private func edged(size: CGFloat = 96) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let violet = PixelProbe.swatch(r: 0.35, g: 0.08, b: 0.75, size: CGSize(width: size / 3, height: size))
            .transformed(by: CGAffineTransform(translationX: size / 3, y: 0))
        return violet.composited(over: PixelProbe.swatch(r: 0.02, g: 0.02, b: 0.02, size: CGSize(width: size, height: size)))
            .cropped(to: extent)
    }

    private let probe = PixelProbe()

    /// A column two pixels wide, so that a measurement means one place in the picture.
    private func chroma(of image: CIImage, atX x: CGFloat) throws -> Float {
        try probe.average(of: image, in: CGRect(x: x, y: 20, width: 2, height: 56)).chroma
    }

    @Test func aNeutralSettingChangesNothing() {
        let image = edged()
        let out = LensCorrectionStage.washed(image, by: PurpleFringe(amount: 0))
        #expect(out === image)
    }

    /// The middle of the band is a flat violet: far from any edge, so it keeps its colour.
    @Test func aFlatVioletIsLeftAlone() throws {
        let image = edged()
        let washed = LensCorrectionStage.washed(image, by: PurpleFringe(amount: 100))
        #expect(try abs(chroma(of: washed, atX: 47) - chroma(of: image, atX: 47)) < 0.05)
    }

    /// And the edge of it loses its colour, which is what a fringe is.
    @Test func theColourGoesWhereThereIsAnEdge() throws {
        let image = edged()
        let washed = LensCorrectionStage.washed(image, by: PurpleFringe(amount: 100))
        #expect(try chroma(of: washed, atX: 33) < chroma(of: image, atX: 33))
    }
}
