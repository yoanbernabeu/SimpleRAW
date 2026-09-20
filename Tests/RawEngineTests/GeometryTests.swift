import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

@Suite struct StraightenMathTests {
    let size = CGSize(width: 600, height: 400)

    @Test func noAngleKeepsTheWholeImage() {
        #expect(Geometry.inscribedSize(in: size, straightenedBy: 0) == size)
    }

    @Test func straighteningCostsPixelsButKeepsTheAspectRatio() {
        let inscribed = Geometry.inscribedSize(in: size, straightenedBy: 10)
        #expect(inscribed.width < size.width)
        #expect(abs(inscribed.width / inscribed.height - 1.5) < 1e-9)
    }

    @Test func leftAndRightTiltsCostTheSame() {
        #expect(Geometry.inscribedSize(in: size, straightenedBy: 7) == Geometry.inscribedSize(in: size, straightenedBy: -7))
    }

    /// The point of the inscribed frame: no empty corner ever shows.
    @Test(arguments: [1.0, 5, 15, 30, 45])
    func theInscribedFrameStaysInsideTheRotatedImage(angle: Double) {
        let inscribed = Geometry.inscribedSize(in: size, straightenedBy: angle)
        let radians = angle * .pi / 180
        for (sx, sy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
            let (x, y) = (sx * inscribed.width / 2, sy * inscribed.height / 2)
            // Back into the image's own axes.
            let u = x * cos(radians) + y * sin(radians)
            let v = -x * sin(radians) + y * cos(radians)
            #expect(abs(u) <= size.width / 2 + 1e-6)
            #expect(abs(v) <= size.height / 2 + 1e-6)
        }
    }
}

/// Keystone correction: the converging verticals of a building shot from below, and the same
/// thing sideways. Like straightening, it costs pixels, and the frame it leaves has no empty
/// corner: `Perspective.scale` says how much of the picture survives.
@Suite struct PerspectiveMathTests {
    /// A frame twice as wide as it is high, as `Perspective` measures it: half-height over
    /// half-width.
    let shape = 0.5

    @Test func nothingTiltedKeepsTheWholeFrame() {
        #expect(Perspective().scale(ofShape: shape) == 1)
        #expect(Perspective().isNeutral)
    }

    /// With one axis alone the answer is exact and can be written down: the edges of the
    /// trapezoid are straight lines, so the largest frame centered on the middle of the
    /// picture is `1 - amount` — then cut down to the step below, which is what keeps a drag
    /// from asking for a different region sixty times a second.
    @Test(arguments: [10.0, 25, 50, 100])
    func oneAxisAloneMatchesTheClosedForm(slider: Double) {
        let amount = Perspective.shift * slider / 100
        for perspective in [Perspective(vertical: slider), Perspective(horizontal: slider)] {
            let scale = perspective.scale(ofShape: shape)
            #expect(scale <= 1 - amount + 1e-9, "\(perspective) keeps more than fits")
            #expect(scale > 1 - amount - Perspective.frameStep, "\(perspective) throws away a whole step too much")
            let steps = scale / Perspective.frameStep
            #expect(abs(steps - steps.rounded()) < 1e-6, "\(perspective) is not on a step")
        }
    }

    /// The middle of the picture is where the frame is centered — it is not where a projective
    /// map leaves it, which is off towards the narrow side.
    @Test func theMiddleOfThePictureIsBroughtBackToTheMiddleOfTheFrame() {
        for perspective in [Perspective(vertical: 70), Perspective(horizontal: -40), Perspective(vertical: 50, horizontal: 50)] {
            let corners = perspective.corners(ofShape: shape)
            // The middle of the picture is where the diagonals cross: the origin is on both.
            for (a, b) in [(corners[0], corners[2]), (corners[1], corners[3])] {
                let cross = (b.x - a.x) * (0 - a.y) - (b.y - a.y) * (0 - a.x)
                #expect(abs(cross) < 1e-9, "\(perspective): the origin is off the diagonal by \(cross)")
            }
        }
    }

    @Test func tiltingOneWayOrTheOtherCostsTheSame() {
        #expect(Perspective(vertical: 30, horizontal: 0).scale(ofShape: shape) == Perspective(vertical: -30, horizontal: 0).scale(ofShape: shape))
        #expect(Perspective(vertical: 0, horizontal: 20).scale(ofShape: shape) == Perspective(vertical: 0, horizontal: -20).scale(ofShape: shape))
    }

    @Test func correctingBothAxesCostsMoreThanEither() {
        let both = Perspective(vertical: 40, horizontal: 40).scale(ofShape: shape)
        #expect(both < Perspective(vertical: 40, horizontal: 0).scale(ofShape: shape))
        #expect(both > 0.4, "a full correction of both axes still leaves most of the picture")
    }

    /// The point of the whole calculation: the frame it keeps is inside the tilted picture,
    /// so no empty corner can show.
    @Test(arguments: [(50.0, 0.0), (0, 50), (35, 35), (-100, 60), (100, -100)])
    func theKeptFrameStaysInsideTheTiltedPicture(vertical: Double, horizontal: Double) {
        let perspective = Perspective(vertical: vertical, horizontal: horizontal)
        let scale = perspective.scale(ofShape: shape)
        let corners = perspective.corners(ofShape: shape)
        var fitsLarger = true
        for (sx, sy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
            let point = (x: sx * scale, y: sy * scale * shape)
            #expect(Perspective.contains(point, in: corners), "\(vertical)/\(horizontal) at \(point)")
            // And it is nearly the largest such frame: a whole step wider already sticks out.
            let wider = (x: point.x * (1 + 2 * Perspective.frameStep), y: point.y * (1 + 2 * Perspective.frameStep))
            fitsLarger = fitsLarger && Perspective.contains(wider, in: corners)
        }
        #expect(!fitsLarger, "\(vertical)/\(horizontal) leaves more room than it takes")
    }

    /// A slider at full scale is a correction worth making, and no more: past that the
    /// picture is mostly thrown away.
    @Test func afullSliderKeepsMostOfThePicture() {
        #expect(Perspective(vertical: 100, horizontal: 0).scale(ofShape: shape) > 0.6)
    }
}

@Suite struct OutputSizeTests {
    let size = CGSize(width: 600, height: 400)

    @Test func aQuarterTurnSwapsTheSides() {
        var geometry = Geometry()
        geometry.quarterTurns = 1
        #expect(geometry.outputSize(for: size) == CGSize(width: 400, height: 600))
        geometry.quarterTurns = 2
        #expect(geometry.outputSize(for: size) == size)
    }

    @Test func croppingScalesTheOutput() {
        var geometry = Geometry()
        geometry.crop = CropRect(x: 0.25, y: 0, width: 0.5, height: 1)
        #expect(geometry.outputSize(for: size) == CGSize(width: 300, height: 400))
    }

    @Test func quarterTurnsWrapAround() {
        var geometry = Geometry()
        geometry.quarterTurns = 5
        #expect(geometry.quarterTurns == 1)
        geometry.quarterTurns = -1
        #expect(geometry.quarterTurns == 3)
    }
}

@Suite struct CropRectEditingTests {
    let full = CropRect.full

    @Test func movingStopsAtTheEdges() {
        let rect = CropRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4).moved(byX: 0.5, y: -0.9)
        #expect(abs(rect.x - 0.6) < 1e-9 && rect.y == 0)
        #expect(abs(rect.width - 0.4) < 1e-9 && abs(rect.height - 0.4) < 1e-9)
    }

    @Test func draggingACornerKeepsTheOppositeOneFixed() {
        let rect = full.resized(dragging: .bottomRight, toX: 0.6, y: 0.7, aspect: nil)
        #expect(rect == CropRect(x: 0, y: 0, width: 0.6, height: 0.7))
        let other = full.resized(dragging: .topLeft, toX: 0.2, y: 0.3, aspect: nil)
        #expect(abs(other.x - 0.2) < 1e-9 && abs(other.maxX - 1) < 1e-9 && abs(other.maxY - 1) < 1e-9)
    }

    @Test func aCropCannotCollapseOrLeaveTheImage() {
        let tiny = full.resized(dragging: .bottomRight, toX: 0.001, y: 0.001, aspect: nil)
        #expect(tiny.width >= CropRect.minimumSide && tiny.height >= CropRect.minimumSide)
        let outside = full.resized(dragging: .bottomRight, toX: 3, y: 3, aspect: nil)
        #expect(outside == full)
    }

    /// `aspect` is the wanted width / height in normalized units (pixel ratio ÷ image ratio).
    @Test func aLockedAspectIsHonoredWhileResizing() {
        let rect = full.resized(dragging: .bottomRight, toX: 0.5, y: 0.9, aspect: 2)
        #expect(abs(rect.width / rect.height - 2) < 1e-9)
        #expect(rect.maxX <= 1 + 1e-9 && rect.maxY <= 1 + 1e-9)
    }

    @Test func fittingAnAspectCentersTheLargestPossibleCrop() {
        let rect = CropRect.largest(withAspect: 0.5)
        #expect(abs(rect.width - 0.5) < 1e-9 && rect.height == 1)
        #expect(abs(rect.x - 0.25) < 1e-9)
    }
}

@Suite struct GeometryTurningTests {
    /// Turning the picture must carry the crop along with it.
    @Test func aQuarterTurnCarriesTheCropAlong() {
        var geometry = Geometry()
        geometry.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.25)  // top-left
        geometry.turn(clockwise: true)
        #expect(geometry.quarterTurns == 1)
        // The top-left corner of the picture is now its top-right corner.
        #expect(geometry.crop == CropRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
    }

    @Test func fourTurnsComeBackToTheStart() {
        var geometry = Geometry()
        geometry.crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let start = geometry
        for _ in 0..<4 { geometry.turn(clockwise: true) }
        #expect(geometry.quarterTurns == start.quarterTurns)
        #expect(abs(geometry.crop!.x - 0.1) < 1e-9 && abs(geometry.crop!.height - 0.4) < 1e-9)
    }

    @Test func turningBackAndForthChangesNothing() {
        var geometry = Geometry()
        geometry.crop = CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        geometry.turn(clockwise: true)
        geometry.turn(clockwise: false)
        #expect(geometry.quarterTurns == 0)
        #expect(abs(geometry.crop!.y - 0.2) < 1e-9 && abs(geometry.crop!.width - 0.3) < 1e-9)
    }
}

@Suite struct GeometryDocumentTests {
    @Test func roundTripsThroughJSON() throws {
        var adjustments = Adjustments()
        adjustments.geometry.straighten = -2.5
        adjustments.geometry.quarterTurns = 1
        adjustments.geometry.perspective = Perspective(vertical: 40, horizontal: -15)
        adjustments.geometry.crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: adjustments.jsonData())
        #expect(decoded == adjustments)
    }

    /// A document written before the field existed opens with no tilt, like every other.
    @Test func editsSavedBeforePerspectiveExistedStillOpen() throws {
        let document = #"{"version": 1, "geometry": {"straighten": 3}}"#
        let decoded = try JSONDecoder().decode(Adjustments.self, from: Data(document.utf8))
        #expect(decoded.geometry.straighten == 3 && decoded.geometry.perspective.isNeutral)
    }

    @Test func aFullCropIsNoCrop() {
        var adjustments = Adjustments()
        adjustments.geometry.crop = .full
        #expect(adjustments == Adjustments())
    }
}

@Suite struct GeometryStageTests {
    let probe = PixelProbe()
    let stage = GeometryStage()
    /// 120 × 80, one color per quadrant: red top-left, green top-right, blue bottom-left,
    /// white bottom-right. "Top" as displayed, i.e. high y in Core Image coordinates.
    let quadrants: CIImage = {
        func patch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, x: CGFloat, y: CGFloat) -> CIImage {
            PixelProbe.swatch(r: r, g: g, b: b, size: CGSize(width: 60, height: 40))
                .transformed(by: CGAffineTransform(translationX: x, y: y))
        }
        return patch(1, 0, 0, x: 0, y: 40)
            .composited(over: patch(0, 1, 0, x: 60, y: 40))
            .composited(over: patch(0, 0, 1, x: 0, y: 0))
            .composited(over: patch(1, 1, 1, x: 60, y: 0))
    }()

    @Test func aClockwiseQuarterTurnMovesTheTopLeftToTheTopRight() throws {
        let output = stage.apply(adjustments { $0.quarterTurns = 1 }, to: quadrants)
        #expect(output.extent == CGRect(x: 0, y: 0, width: 80, height: 120))
        let topRight = try probe.average(of: output, in: CGRect(x: 50, y: 70, width: 20, height: 40))
        #expect(topRight.r > 0.9 && topRight.g < 0.1 && topRight.b < 0.1)
    }

    @Test func croppingKeepsTheChosenPart() throws {
        // The top-right quadrant, in top-left-origin normalized coordinates.
        let output = stage.apply(adjustments { $0.crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 0.5) }, to: quadrants)
        #expect(output.extent == CGRect(x: 0, y: 0, width: 60, height: 40))
        let pixel = try probe.average(of: output)
        #expect(pixel.g > 0.9 && pixel.r < 0.1 && pixel.b < 0.1)
    }

    @Test func straighteningLeavesNoEmptyCorner() throws {
        let white = PixelProbe.swatch(r: 1, g: 1, b: 1, size: CGSize(width: 300, height: 200))
        let output = stage.apply(adjustments { $0.straighten = 12 }, to: white)
        let expected = Geometry.inscribedSize(in: CGSize(width: 300, height: 200), straightenedBy: 12)
        #expect(abs(output.extent.width - expected.width) <= 1)
        #expect(output.extent.origin == .zero)
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: output.extent.maxX - 3, y: output.extent.maxY - 3)] {
            let pixel = try probe.average(of: output, in: CGRect(origin: corner, size: CGSize(width: 3, height: 3)))
            #expect(pixel.luminance > 0.97)
        }
    }

    /// Positive angles turn the picture clockwise, as seen on screen.
    @Test func positiveStraightenTurnsClockwise() throws {
        let output = stage.apply(adjustments { $0.straighten = 20 }, to: quadrants)
        let extent = output.extent
        // Clockwise, red (top-left) spills over the top edge toward the right of center.
        let topCenterRight = try probe.average(of: output, in: CGRect(x: extent.midX + 2, y: extent.maxY - 6, width: 6, height: 4))
        #expect(topCenterRight.r > topCenterRight.g)
    }

    private func adjustments(_ edit: (inout Geometry) -> Void) -> Adjustments {
        var adjustments = Adjustments()
        edit(&adjustments.geometry)
        return adjustments
    }
}
