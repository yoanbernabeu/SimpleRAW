import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// Looks are chosen with the eyes: each one shows the open photo as it would become, and
/// hovering one tries it on the canvas without touching the settings.
@MainActor
@Suite struct LookPreviewTests {
    let session = DevelopSession()
    let probe = PixelProbe()
    let viewSize = CGSize(width: 750, height: 500)

    init() {
        session.open(TestPhoto.url)
    }

    private var blackAndWhite: Preset {
        get throws { try #require(session.presets.first { $0.name == "Black & white" }) }
    }

    @Test func hoveringALookShowsItWithoutChangingAnything() throws {
        let before = try probe.average(of: try #require(session.previewImage(fitting: viewSize)))
        session.previewedPreset = try blackAndWhite
        let tried = try probe.average(of: try #require(session.previewImage(fitting: viewSize)))
        #expect(abs(tried.r - tried.b) < 0.02 && abs(before.r - before.b) > 0.02, "the canvas went gray")
        #expect(session.adjustments == Adjustments() && !session.canUndo)

        session.previewedPreset = nil
        let after = try probe.average(of: try #require(session.previewImage(fitting: viewSize)))
        #expect(abs(after.r - before.r) < 0.005)
    }

    @Test func theLookInUseIsKnown() throws {
        #expect(!session.isApplied(try blackAndWhite), "nothing is applied to an untouched photo")
        session.apply(try blackAndWhite)
        #expect(session.isApplied(try blackAndWhite))
        session.adjustments.blackAndWhite.isEnabled = false
        #expect(!session.isApplied(try blackAndWhite))
    }

    /// A new look proposes what was actually changed, not eleven boxes to think about.
    @Test func aNewLookProposesTheGroupsThatWereEdited() {
        #expect(session.editedGroups.isEmpty)
        session.adjustments.contrast = 20
        session.adjustments.hsl[.blue].saturation = -30
        session.adjustments.geometry.straighten = 2
        // The framing belongs to one photo: it is never proposed for a look.
        #expect(session.editedGroups == [.light, .hsl])
    }

    /// Pasting the white balance of one photo on a series, and nothing else, is an everyday
    /// move: what is copied can be chosen, and the choice is remembered for the next copy.
    @Test func copyingCanBeLimitedToSomeGroups() {
        session.adjustments.contrast = 20
        session.adjustments.vibrance = 30
        session.copiedGroups = [.color]
        session.copyAdjustments()

        session.adjustments = Adjustments()
        session.pasteAdjustments()
        #expect(session.adjustments.vibrance == 30 && session.adjustments.contrast == 0)
        #expect(session.copiedGroups == [.color], "remembered for the next copy")
    }

    @Test func everyLookGetsAThumbnailOfTheOpenPhoto() async throws {
        session.showsLookThumbnails = true
        await session.lookThumbnailsSettled()
        #expect(Set(session.lookThumbnails.keys) == Set(session.presets.map(\.name)))
        let gray = try probe.average(of: CIImage(cgImage: try #require(session.lookThumbnails["Black & white"])))
        #expect(abs(gray.r - gray.b) < 0.02)
        let thumbnail = try #require(session.lookThumbnails.values.first)
        #expect(max(thumbnail.width, thumbnail.height) <= 320, "small: there is a grid of them")
    }

    @Test func thumbnailsFollowTheEditsOnceTheySettle() async throws {
        session.showsLookThumbnails = true
        await session.lookThumbnailsSettled()
        // A look that leaves the light alone: the others bring their own exposure.
        let name = try blackAndWhite.name
        let before = try probe.average(of: CIImage(cgImage: try #require(session.lookThumbnails[name])))
        session.adjustments.exposure = 1.5
        session.commitEdit()
        await session.lookThumbnailsSettled()
        let after = try probe.average(of: CIImage(cgImage: try #require(session.lookThumbnails[name])))
        #expect(after.luminance > before.luminance + 0.05)
    }
}

/// A look just applied can be dosed from 0 to 100 %: the slider goes back and forth between
/// the settings of before and the look, and never piles the look onto itself.
@MainActor
@Suite struct LookAmountSessionTests {
    let session = DevelopSession()

    init() {
        session.open(TestPhoto.url)
    }

    private var contrasted: Preset {
        var look = Adjustments()
        look.contrast = 40
        look.vibrance = 20
        return Preset(name: "Punchy", capturing: look, groups: [.light, .color])
    }

    @Test func applyingALookOpensItsAmountAtFull() {
        #expect(session.dosedLook == nil, "nothing to dose before a look is applied")
        session.apply(contrasted)
        #expect(session.dosedLook?.name == "Punchy" && session.lookAmount == 1)
        #expect(session.adjustments.contrast == 40)
    }

    @Test func slidingTheAmountRecomputesFromTheSettingsOfBefore() {
        session.adjustments.exposure = 0.5
        session.commitEdit()
        session.apply(contrasted)

        session.setLookAmount(0.5)
        #expect(session.adjustments.contrast == 20 && session.adjustments.vibrance == 10)
        // Back and forth: the look never piles onto itself.
        session.setLookAmount(0.25)
        #expect(session.adjustments.contrast == 10)
        session.setLookAmount(1)
        #expect(session.adjustments.contrast == 40)
        session.setLookAmount(0)
        #expect(session.adjustments == { var a = Adjustments(); a.exposure = 0.5; return a }())
    }

    @Test func theWholeDosingIsOneUndoStep() {
        session.adjustments.exposure = 0.5
        session.commitEdit()
        let before = session.adjustments

        session.apply(contrasted)
        for amount in [0.9, 0.7, 0.5, 0.4] { session.setLookAmount(amount) }
        session.commitEdit()
        #expect(abs(session.adjustments.contrast - 16) < 0.001)

        session.undo()
        #expect(session.adjustments == before, "one step back is the photo before the look")
    }

    /// The amount belongs to the look that was just applied: any other edit closes it, and so
    /// does opening another photo.
    @Test func anEditOfItsOwnClosesTheAmount() {
        session.apply(contrasted)
        #expect(session.dosedLook != nil)
        session.adjustments.shadows = 30
        #expect(session.dosedLook == nil)

        session.apply(contrasted)
        session.open(TestPhoto.url)
        #expect(session.dosedLook == nil)
    }

    /// Undoing the look takes its slider away with it: there is nothing to dose any more.
    @Test func undoingTheLookClosesTheAmount() {
        session.apply(contrasted)
        session.undo()
        #expect(session.dosedLook == nil && !session.hasChanges)
    }
}
