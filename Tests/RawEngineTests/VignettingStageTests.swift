import CoreImage
import Testing
import TestSupport
@testable import RawEngine

/// Measured on a uniform gray: whatever is not flat afterwards is the stage's doing.
@Suite struct VignettingStageTests {
    let probe = PixelProbe()
    let stage = VignettingStage()
    let gray: Float = 0.2

    @Test func runsFirstSoThatItCorrectsLinearSensorData() {
        #expect(DevelopPipeline.standard.stages.first is VignettingStage)
    }

    @Test func positiveAmountBrightensCornersAndLeavesTheCenterAlone() throws {
        let output = stage.apply(adjustments(100), to: swatch())
        #expect(abs(try center(of: output) - gray) < 0.004)
        // +100 is two stops at the very corner; the sampled patch sits just inside it.
        #expect(try corner(of: output) > gray * 3.4)
    }

    @Test func negativeAmountDarkensCorners() throws {
        let output = stage.apply(adjustments(-100), to: swatch())
        #expect(abs(try center(of: output) - gray) < 0.004)
        #expect(try corner(of: output) < gray * 0.32)
    }

    /// gain = 1 + k·r²: halfway to the corner, a quarter of the corner's boost.
    @Test func falloffIsQuadratic() throws {
        let size = CGSize(width: 256, height: 256)
        let output = stage.apply(adjustments(100), to: swatch(size))
        let halfway = try probe.average(of: output, in: CGRect(x: 190, y: 190, width: 4, height: 4)).luminance
        #expect(abs(halfway / gray - (1 + 3 * 0.25)) < 0.06)
    }

    @Test func isRadiallySymmetric() throws {
        let size = CGSize(width: 120, height: 80)
        let output = stage.apply(adjustments(60), to: swatch(size))
        let corners = try [
            CGRect(x: 0, y: 0, width: 4, height: 4),
            CGRect(x: 116, y: 0, width: 4, height: 4),
            CGRect(x: 0, y: 76, width: 4, height: 4),
            CGRect(x: 116, y: 76, width: 4, height: 4),
        ].map { try probe.average(of: output, in: $0).luminance }
        #expect(corners.max()! - corners.min()! < 0.004)
    }

    /// A preview and the full-size export must get the same correction.
    @Test func doesNotDependOnResolution() throws {
        let small = stage.apply(adjustments(50), to: swatch(CGSize(width: 60, height: 40)))
        let large = stage.apply(adjustments(50), to: swatch(CGSize(width: 600, height: 400)))
        let smallCorner = try probe.average(of: small, in: CGRect(x: 0, y: 0, width: 3, height: 2)).luminance
        let largeCorner = try probe.average(of: large, in: CGRect(x: 0, y: 0, width: 30, height: 20)).luminance
        #expect(abs(smallCorner - largeCorner) < 0.006)
    }

    @Test func keepsTheImageExtent() {
        let input = swatch(CGSize(width: 120, height: 80))
        #expect(stage.apply(adjustments(40), to: input).extent == input.extent)
    }

    // MARK: - Helpers

    private func adjustments(_ vignetting: Double) -> Adjustments {
        var adjustments = Adjustments()
        adjustments.vignetting = vignetting
        return adjustments
    }

    private func swatch(_ size: CGSize = CGSize(width: 64, height: 64)) -> CIImage {
        PixelProbe.swatch(r: CGFloat(gray), g: CGFloat(gray), b: CGFloat(gray), size: size)
    }

    private func center(of image: CIImage) throws -> Float {
        let extent = image.extent
        return try probe.average(of: image, in: CGRect(x: extent.midX - 1, y: extent.midY - 1, width: 2, height: 2)).luminance
    }

    private func corner(of image: CIImage) throws -> Float {
        try probe.average(of: image, in: CGRect(x: 0, y: 0, width: 2, height: 2)).luminance
    }
}
