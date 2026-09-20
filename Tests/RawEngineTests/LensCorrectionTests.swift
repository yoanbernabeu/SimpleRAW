import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// The keystone correction, as the pipeline applies it: early, with the optical corrections,
/// and not with the crop. `PerspectiveMathTests` covers the geometry it is built on.
@Suite struct LensCorrectionStageTests {
    let probe = PixelProbe()
    let stage = LensCorrectionStage()

    private func adjustments(_ perspective: Perspective) -> Adjustments {
        var adjustments = Adjustments()
        adjustments.geometry.perspective = perspective
        return adjustments
    }

    /// A white picture with a narrow red bar standing just right of center, full height.
    /// A keystone correction makes the bar lean; where it leans says which way it works.
    private func barredPicture(width: Int = 200, height: Int = 200) -> CIImage {
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let bar = PixelProbe.swatch(r: 1, g: 0, b: 0, size: CGSize(width: size.width * 0.05, height: size.height))
            .transformed(by: CGAffineTransform(translationX: size.width * 0.55, y: 0))
        return bar.composited(over: PixelProbe.swatch(r: 1, g: 1, b: 1, size: size))
    }

    @Test func aNeutralCorrectionCostsNothing() {
        let white = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 120, height: 80))
        #expect(stage.apply(adjustments(Perspective()), to: white).extent == white.extent)
    }

    @Test func aCorrectionLeavesNoEmptyCornerAndTheSizeGeometryPromised() throws {
        let size = CGSize(width: 300, height: 200)
        let perspective = Perspective(vertical: 60, horizontal: 25)
        let output = stage.apply(adjustments(perspective), to: PixelProbe.swatch(r: 1, g: 1, b: 1, size: size))
        // `Geometry.frameSize` has to agree with what the stage actually cuts: the crop
        // overlay and the export size are both computed from it.
        let expected = Geometry.perspective(perspective).frameSize(for: size)
        #expect(abs(output.extent.width - expected.width) <= 1 && abs(output.extent.height - expected.height) <= 1)
        let extent = output.extent
        for corner in [CGPoint(x: extent.minX, y: extent.minY), CGPoint(x: extent.maxX - 3, y: extent.minY),
                       CGPoint(x: extent.minX, y: extent.maxY - 3), CGPoint(x: extent.maxX - 3, y: extent.maxY - 3)] {
            let pixel = try probe.average(of: output, in: CGRect(origin: corner, size: CGSize(width: 3, height: 3)))
            #expect(pixel.luminance > 0.97, "empty corner at \(corner)")
        }
    }

    /// Positive leans the top of the frame out, which pulls what is at the top of the picture
    /// towards the middle: a bar standing right of center comes to lean left.
    @Test func aPositiveVerticalPullsTheTopOfThePictureIn() throws {
        let output = stage.apply(adjustments(Perspective(vertical: 100)), to: barredPicture())
        let extent = output.extent
        func redness(atX x: CGFloat, y: CGFloat) throws -> Double {
            let pixel = try probe.average(of: output, in: CGRect(x: x, y: y, width: 4, height: 4))
            return Double(pixel.r - pixel.g)
        }
        let inward = extent.minX + extent.width * 0.55
        let outward = extent.minX + extent.width * 0.63
        #expect(try redness(atX: inward, y: extent.maxY - 6) > 0.5, "the bar leans in at the top")
        #expect(try redness(atX: inward, y: extent.minY + 2) < 0.2, "and is no longer there at the bottom")
        #expect(try redness(atX: outward, y: extent.minY + 2) > 0.5, "the bar leans out at the bottom")
    }

    /// What the photographer aimed at must not walk off while the slider moves.
    @Test func theMiddleOfThePictureStaysPut() throws {
        let size = CGSize(width: 200, height: 200)
        let spot = PixelProbe.swatch(r: 0, g: 0, b: 1, size: CGSize(width: 20, height: 20))
            .transformed(by: CGAffineTransform(translationX: 90, y: 90))
            .composited(over: PixelProbe.swatch(r: 1, g: 1, b: 1, size: size))
        for perspective in [Perspective(vertical: 80), Perspective(horizontal: -80), Perspective(vertical: 50, horizontal: 50)] {
            let output = stage.apply(adjustments(perspective), to: spot)
            let middle = try probe.average(of: output, in: CGRect(x: output.extent.midX - 2, y: output.extent.midY - 2, width: 4, height: 4))
            #expect(middle.b > 0.9 && middle.r < 0.1, "\(perspective)")
        }
    }

    /// A black-to-white edge standing well away from the middle of the frame: what a lens
    /// leaves a coloured fringe along, and what shows whether the fringe has been pulled back.
    private func edgedPicture(width: CGFloat = 1200, height: CGFloat = 40, edge: CGFloat = 1100) -> CIImage {
        PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: width - edge, height: height))
            .transformed(by: CGAffineTransform(translationX: edge, y: 0))
            .composited(over: PixelProbe.swatch(r: 0, g: 0, b: 0, size: CGSize(width: width, height: height)))
    }

    @Test func aNeutralAberrationCostsNothing() {
        let picture = edgedPicture()
        let output = LensCorrectionStage.deFringed(picture, by: ChromaticAberration())
        #expect(output === picture)
    }

    /// Magnifying the red channel carries red detail away from the middle: the red edge lands
    /// beyond the green one, so the far side of the edge reads cyan for those few pixels.
    /// Shrinking it does the opposite, and leaves red on the near side.
    ///
    /// The edge is 500 px from the middle and a full slider is half a percent, so everything
    /// here happens within two and a half pixels of x = 1100.
    @Test func magnifyingTheRedChannelCarriesRedOutwards() throws {
        let outwards = LensCorrectionStage.deFringed(edgedPicture(), by: ChromaticAberration(redCyan: 100))
        #expect(outwards.extent == CGRect(x: 0, y: 0, width: 1200, height: 40))
        let cyan = try probe.average(of: outwards, in: CGRect(x: 1100, y: 10, width: 1, height: 20))
        #expect(cyan.g > 0.8 && cyan.b > 0.8 && cyan.r < 0.2, "no cyan beyond the edge: \(cyan)")

        let inwards = LensCorrectionStage.deFringed(edgedPicture(), by: ChromaticAberration(redCyan: -100))
        let red = try probe.average(of: inwards, in: CGRect(x: 1098, y: 10, width: 1, height: 20))
        #expect(red.r > 0.8 && red.g < 0.2 && red.b < 0.2, "no red before the edge: \(red)")
    }

    @Test func magnifyingTheBlueChannelCarriesBlueOutwards() throws {
        let outwards = LensCorrectionStage.deFringed(edgedPicture(), by: ChromaticAberration(blueYellow: 100))
        let yellow = try probe.average(of: outwards, in: CGRect(x: 1100, y: 10, width: 1, height: 20))
        #expect(yellow.r > 0.8 && yellow.g > 0.8 && yellow.b < 0.2, "no yellow beyond the edge: \(yellow)")
    }

    /// Away from the edges, a correction of this size changes nothing anyone can see, and the
    /// picture stays opaque and grey where it was grey.
    @Test func theMiddleOfAFlatPictureIsLeftAlone() throws {
        let grey = PixelProbe.swatch(r: 0.5, g: 0.5, b: 0.5, size: CGSize(width: 400, height: 300))
        let output = LensCorrectionStage.deFringed(grey, by: ChromaticAberration(redCyan: 100, blueYellow: -100))
        let pixel = try probe.average(of: output, in: CGRect(x: 190, y: 140, width: 20, height: 20))
        // Half a grey that came back half a grey is also the proof that the three channels
        // were put together with an alpha of one: premultiplied by nothing, it would be black.
        #expect(abs(pixel.r - 0.5) < 0.01 && abs(pixel.g - 0.5) < 0.01 && abs(pixel.b - 0.5) < 0.01)
    }

    /// Distortion correction needs the Metal kernel. Where the build had no compiler for it,
    /// there is nothing to test and nothing offered: the tests say which case they are in
    /// rather than passing quietly either way.
    @Test func distortionCorrectionPullsTheEdgesIn() throws {
        try #require(MetalKernels.isAvailable, "built without a Metal compiler: no kernel to test")
        // A white band from x = 300 to the right edge of a 400 × 200 picture: its edge is
        // 100 px out from the middle, far enough for the correction to move it.
        let picture = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 100, height: 200))
            .transformed(by: CGAffineTransform(translationX: 300, y: 0))
            .composited(over: PixelProbe.swatch(r: 0, g: 0, b: 0, size: CGSize(width: 400, height: 200)))
        // At that radius a full slider is worth two percent, so the edge moves by two pixels:
        // measured where it lands, not where it would be convenient.
        #expect(try probe.average(of: picture, in: CGRect(x: 299, y: 90, width: 1, height: 20)).luminance < 0.1)
        #expect(try probe.average(of: picture, in: CGRect(x: 301, y: 90, width: 1, height: 20)).luminance > 0.9)

        // Positive pulls the edges in: the white band now reaches x = 299.
        let corrected = LensCorrectionStage.straightenedLines(picture, by: 100)
        #expect(corrected.extent == picture.extent)
        #expect(try probe.average(of: corrected, in: CGRect(x: 299, y: 90, width: 1, height: 20)).luminance > 0.9)
        // And negative pushes them out: x = 301 has gone back to black.
        let pushed = LensCorrectionStage.straightenedLines(picture, by: -100)
        #expect(try probe.average(of: pushed, in: CGRect(x: 301, y: 90, width: 1, height: 20)).luminance < 0.1)
    }

    @Test func aNeutralDistortionCostsNothing() {
        let white = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 120, height: 80))
        #expect(LensCorrectionStage.straightenedLines(white, by: 0) === white)
    }

    /// The middle of the picture is where nothing moves: `r = 0`, whatever the coefficient.
    @Test func theMiddleOfThePictureIsWhereNothingMoves() throws {
        try #require(MetalKernels.isAvailable, "built without a Metal compiler: no kernel to test")
        let size = CGSize(width: 300, height: 300)
        let spot = PixelProbe.swatch(r: 0, g: 0, b: 1, size: CGSize(width: 16, height: 16))
            .transformed(by: CGAffineTransform(translationX: 142, y: 142))
            .composited(over: PixelProbe.swatch(r: 1, g: 1, b: 1, size: size))
        let corrected = LensCorrectionStage.straightenedLines(spot, by: 100)
        let middle = try probe.average(of: corrected, in: CGRect(x: 146, y: 146, width: 8, height: 8))
        #expect(middle.b > 0.9 && middle.r < 0.1)
    }

    /// The order is part of the contract: the correction is made before the blurs, and the
    /// crop stays last. Measured, not assumed — a homography after the blurs made Core Image
    /// keep a new set of them for every frame of a drag, and the machine ran out of memory.
    @Test func theCorrectionIsMadeBeforeEverythingButVignetting() throws {
        let stages = DevelopPipeline.standard.stages
        let lens = try #require(stages.firstIndex { $0 is LensCorrectionStage })
        let vignetting = try #require(stages.firstIndex { $0 is VignettingStage })
        let contrast = try #require(stages.firstIndex { $0 is LocalContrastStage })
        let geometry = try #require(stages.firstIndex { $0 is GeometryStage })
        #expect(vignetting < lens && lens < contrast && contrast < geometry)
    }
}

/// The kernel is optional at build time. These say which case this build is in, out loud:
/// a suite that passes either way must at least report which way it passed.
@Suite struct MetalKernelTests {
    @Test func theBuildSaysWhetherItCanWarpAPicture() {
        print("BUILD: Metal kernels \(MetalKernels.isAvailable ? "compiled in" : "left out (no Metal compiler)")")
        #expect(MetalKernels.isAvailable || !MetalKernels.isAvailable)
    }

    /// Without the kernel the slider is not offered, and the stage leaves the picture alone.
    /// With it, both are there. One rule, read the same way by the engine and the inspector.
    @Test func whatIsOfferedFollowsWhatTheBuildCanDo() {
        let white = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 100, height: 60))
        let corrected = LensCorrectionStage.straightenedLines(white, by: 100)
        #expect((corrected !== white) == MetalKernels.isAvailable)
    }

    /// A name the library does not hold answers nothing, rather than throwing on every frame.
    @Test func anUnknownKernelIsSimplyMissing() {
        #expect(MetalKernels.warp("noSuchKernel") == nil)
    }
}
