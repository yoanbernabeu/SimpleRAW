import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

@MainActor
@Suite
struct LocalToolsTests {
    let session = DevelopSession()
    let probe = PixelProbe()
    let viewSize = CGSize(width: 750, height: 500)

    init() throws {
        session.open(TestPhoto.url)
    }

    @Test func addingAMaskSelectsItAndOpensTheTool() throws {
        session.addLocal(.linear)
        let local = try #require(session.adjustments.locals.first)
        #expect(session.selectedLocalID == local.id)
        #expect(session.tool == .local)
        if case .linear = local.mask {} else { Issue.record("expected a linear mask") }
    }

    /// Drawn on a 3:2 frame, a new radial mask must look like a circle.
    @Test func aNewRadialMaskIsRoundOnScreen() throws {
        session.addLocal(.radial)
        guard case .radial(let mask) = try #require(session.adjustments.locals.first).mask else {
            Issue.record("expected a radial mask"); return
        }
        let frame = try #require(session.info).imageSize
        #expect(abs(mask.radiusX * frame.width - mask.radiusY * frame.height) < 1)
    }

    @Test func removingTheSelectedMaskSelectsNothing() {
        session.addLocal(.linear)
        session.addLocal(.radial)
        session.removeSelectedLocal()
        #expect(session.adjustments.locals.count == 1)
        #expect(session.selectedLocalID == nil)
    }

    @Test func slidersOfTheSelectedMaskEditItsSettings() throws {
        session.addLocal(.linear)
        let id = try #require(session.selectedLocalID)
        let context = try #require(session.sliderContext)
        let exposure = try #require(SliderSpec.local(id: id).first)
        exposure.setValue(&session.adjustments, 1.5, context)
        #expect(session.adjustments.locals[0].settings.exposure == 1.5)
        exposure.reset(&session.adjustments, context)
        #expect(session.adjustments.locals[0].settings.isNeutral)
    }

    /// A setting a layer can hold that no slider reaches is a setting nobody can use: every
    /// field of `LocalSettings` has its own entry in the panel, and writes only itself.
    @Test func everyLocalSettingHasASliderThatWritesAndResets() throws {
        session.addLocal(.linear)
        let id = try #require(session.selectedLocalID)
        let context = try #require(session.sliderContext)
        let specs = SliderSpec.local(id: id)

        let encoded = try JSONEncoder().encode(LocalSettings())
        let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        #expect(Set(specs.map(\.title)) == Set(fields.map { $0.prefix(1).uppercased() + $0.dropFirst() }))

        for spec in specs {
            spec.setValue(&session.adjustments, spec.range.upperBound, context)
            #expect(spec.value(session.adjustments, context) == spec.range.upperBound, "\(spec.title)")
            spec.reset(&session.adjustments, context)
        }
        #expect(session.adjustments.locals[0].settings.isNeutral, "every slider goes back to neutral")
    }

    @Test func slidersOfAMaskThatIsGoneDoNothing() throws {
        session.addLocal(.linear)
        let id = try #require(session.selectedLocalID)
        let context = try #require(session.sliderContext)
        session.removeSelectedLocal()
        let exposure = try #require(SliderSpec.local(id: id).first)
        exposure.setValue(&session.adjustments, 1, context)
        #expect(session.adjustments.locals.isEmpty)
        #expect(exposure.value(session.adjustments, context) == 0)
    }

    /// Masks live in the uncropped, unrotated frame: that is what local tools must show.
    @Test func localToolsShowTheOriginalFrame() throws {
        session.adjustments.geometry.quarterTurns = 1
        session.adjustments.geometry.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        session.tool = .local
        let shown = try #require(session.previewImage(fitting: viewSize)).extent.size
        #expect(shown.width > shown.height)
        #expect(session.adjustments.geometry.quarterTurns == 1)
    }

    @Test func paintingBuildsAStroke() throws {
        session.addLocal(.brush)
        session.brushRadius = 0.04
        session.beginStroke(at: .init(x: 0.2, y: 0.5))
        session.continueStroke(to: .init(x: 0.2005, y: 0.5))  // too close: skipped
        session.continueStroke(to: .init(x: 0.4, y: 0.5))
        session.endStroke()
        guard case .brush(let mask) = session.adjustments.locals[0].mask else { Issue.record("expected a brush"); return }
        #expect(mask.strokes.count == 1)
        #expect(mask.strokes[0].points.count == 2 && mask.strokes[0].radius == 0.04)

        session.isErasing = true
        session.beginStroke(at: .init(x: 0.3, y: 0.5))
        session.endStroke()
        guard case .brush(let erased) = session.adjustments.locals[0].mask else { return }
        #expect(erased.strokes.count == 2 && erased.strokes[1].isErasing)
    }

    /// The red veil says where a mask is while there is nothing else to see. Once the layer
    /// does something, the effect shows it better, and the veil would hide it.
    @Test func theMaskVeilGivesWayToTheEffect() throws {
        session.addLocal(.radial)
        let id = try #require(session.selectedLocalID)
        #expect(session.showsMaskOverlay, "a new mask does nothing yet")

        session.adjustments[local: id].exposure = 1
        session.commitEdit()
        #expect(!session.showsMaskOverlay, "the slider moved: the picture shows the effect")

        guard case .radial(var mask) = session.selectedLocal?.mask else { return }
        mask.center = NormalizedPoint(x: 0.4, y: 0.4)
        session.updateSelectedMask(.radial(mask))
        #expect(session.showsMaskOverlay, "while the mask is being moved")
        session.commitEdit()
        #expect(!session.showsMaskOverlay, "and no longer once it settles")

        session.keepsMaskOverlay = true
        #expect(session.showsMaskOverlay, "O keeps it on")
        session.tool = .none
        #expect(!session.showsMaskOverlay)
    }

    /// Local tools show the uncropped frame: the crop is drawn over it when it can be.
    @Test func theCropIsShownOverTheOriginalFrameUnlessThePictureIsTurned() {
        #expect(session.cropShownByLocalTools == nil)
        let crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        session.adjustments.geometry.crop = crop
        #expect(session.cropShownByLocalTools == crop)
        session.adjustments.geometry.straighten = 2
        #expect(session.cropShownByLocalTools == nil, "tilted: a rectangle would lie")
    }

    @Test func theMaskOverlayShowsWhereTheEffectGoes() throws {
        session.addLocal(.linear)  // top of the picture
        session.tool = .none
        let plain = try #require(session.previewImage(fitting: viewSize))
        session.tool = .local
        let tinted = try #require(session.previewImage(fitting: viewSize))
        let top = CGRect(x: 100, y: plain.extent.height - 40, width: 200, height: 30)
        let bottom = CGRect(x: 100, y: 10, width: 200, height: 30)
        let (before, after) = (try probe.average(of: plain, in: top), try probe.average(of: tinted, in: top))
        #expect(after.r - after.b > before.r - before.b + 0.05)
        #expect(abs(try probe.average(of: tinted, in: bottom).r - probe.average(of: plain, in: bottom).r) < 0.01)
    }

    @Test func aSpotGetsASourceNextToItInsideTheFrame() throws {
        session.tool = .spots
        session.addSpot(at: .init(x: 0.98, y: 0.5))
        let spot = try #require(session.adjustments.spots.first)
        #expect(spot.target == NormalizedPoint(x: 0.98, y: 0.5))
        #expect(spot.source != spot.target)
        #expect((0...1).contains(spot.source.x) && (0...1).contains(spot.source.y))
        #expect(session.selectedSpotID == spot.id)

        session.removeSelectedSpot()
        #expect(session.adjustments.spots.isEmpty)
    }

    /// A wire is not a dust spot: dragging draws a line along it, healed in one go.
    @Test func draggingDrawsALineAlongTheBlemish() throws {
        session.tool = .spots
        session.beginHealingLine(at: .init(x: 0.2, y: 0.5))
        // A drag reports points far closer together than a stroke needs: four hundred of them.
        var reported = 0
        for step in 1...400 {
            session.continueHealingLine(to: .init(x: 0.2 + Double(step) * 0.001, y: 0.5))
            reported += 1
        }
        session.endHealingLine()

        let spot = try #require(session.adjustments.spots.first)
        #expect(spot.isLine)
        #expect(spot.target == NormalizedPoint(x: 0.2, y: 0.5))
        #expect(spot.points.last?.x ?? 0 > 0.55, "the line reaches the end of what was drawn")
        // Each point costs a disc, so the ones that add nothing are dropped: what is kept is
        // spaced by a share of the radius, however fast the pointer is sampled.
        #expect(spot.points.count < reported / 3, "\(spot.points.count) points for \(reported) reported")
        let spacing = DevelopSession.healingLineStep * spot.radius
        for (first, second) in zip(spot.points, spot.points.dropFirst()) {
            #expect(hypot(second.x - first.x, second.y - first.y) >= spacing - 1e-9)
        }
        #expect(session.adjustments.spots.count == 1, "one line, one spot")
    }

    /// A click is still a spot: the drag gesture that draws a line starts as one.
    @Test func aDragThatNeverMovesIsStillASpot() throws {
        session.tool = .spots
        session.beginHealingLine(at: .init(x: 0.4, y: 0.4))
        session.continueHealingLine(to: .init(x: 0.4, y: 0.4))
        session.endHealingLine()
        let spot = try #require(session.adjustments.spots.first)
        #expect(!spot.isLine && spot.target == NormalizedPoint(x: 0.4, y: 0.4))
    }

    /// Whatever it is, it is one undo step, taken when the gesture settles.
    @Test func aLineIsOneUndoStep() {
        session.tool = .spots
        session.adjustments.contrast = 12
        session.commitEdit()
        session.beginHealingLine(at: .init(x: 0.2, y: 0.5))
        for x in stride(from: 0.22, through: 0.5, by: 0.02) { session.continueHealingLine(to: .init(x: x, y: 0.5)) }
        session.endHealingLine()
        #expect(session.adjustments.spots.count == 1)

        session.undo()
        #expect(session.adjustments.spots.isEmpty && session.adjustments.contrast == 12)
    }

    @Test func theCropToolIsStillATool() {
        session.isCropping = true
        #expect(session.tool == .crop)
        session.tool = .none
        #expect(!session.isCropping)
    }
}
