import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// Asking the machine for a mask, and what happens while it has not answered.
///
/// What Vision finds in a given photograph is Apple's business and changes between releases,
/// so nothing here asserts that a subject *was* found. What is asserted is everything around
/// it: that the asking happens off the main actor, that a layer with no answer changes
/// nothing, that an answer makes the canvas draw again, and that the document stays small.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DetectedMaskSessionTests {
    let session = DevelopSession()
    let probe = PixelProbe()
    let viewSize = CGSize(width: 400, height: 300)

    init() throws {
        MaskRasterStore.shared.removeAll()
        // Never the folder a person's app uses: a test that leaves a mask behind would make
        // the next run skip the very search it is there to exercise.
        session.maskCache = MaskRasterCache(folder: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        session.open(TestPhoto.url)
    }

    /// A layer that is waiting for its mask must leave the photograph exactly as it was.
    @Test func aLayerWaitingForItsMaskChangesNothing() throws {
        let plain = try #require(session.previewImage(fitting: viewSize))
        let before = try probe.average(of: plain)

        session.addLocal(.subject)
        session.adjustments.locals[0].settings.exposure = 2
        let waiting = try #require(session.previewImage(fitting: viewSize))
        let after = try probe.average(of: waiting)
        #expect(abs(after.luminance - before.luminance) < 0.001, "the picture moved before the mask arrived")
    }

    @Test func askingForOneIsALayerLikeAnyOther() async throws {
        session.addLocal(.person)
        await session.masksSettled()
        let local = try #require(session.adjustments.locals.first)
        #expect(local.mask.kind == .person)
        #expect(session.selectedLocalID == local.id && session.tool == .local)

        // It is undone like any other layer, and forgotten.
        session.undo()
        #expect(session.adjustments.locals.isEmpty)
    }

    /// The answer arrives from outside `adjustments`, so something has to tell the canvas.
    @Test func anAnswerMakesTheCanvasDrawAgain() async throws {
        session.addLocal(.subject)
        let before = session.maskRevision
        await session.masksSettled()
        guard case .detected(let mask) = session.adjustments.locals.first?.mask else {
            Issue.record("the layer does not carry a found mask")
            return
        }
        // Vision may find nothing in a generated test photo: both ways are correct, and each
        // says the same thing about the plumbing.
        if session.hasRaster(for: mask) {
            #expect(session.maskRevision > before, "a mask arrived and nothing told the canvas")
            let shown = try #require(session.previewImage(fitting: viewSize))
            #expect(shown.extent.width > 0)
        } else {
            #expect(session.maskRevision == before, "nothing was found, so nothing should have moved")
        }
    }

    /// Opening another photo drops what was being looked for in the last one.
    @Test func openingAnotherPhotoStopsLookingForTheLastOne() async throws {
        session.addLocal(.subject)
        session.open(TestPhoto.url)
        await session.masksSettled()
        #expect(session.adjustments.locals.isEmpty, "the new photo has no layers")
    }

    /// The same brush as a painted mask, on what was found. This is what makes the tool
    /// usable when detection is a few pixels off — and it shows before Vision has answered.
    @Test func aFoundMaskTakesTheBrush() async throws {
        let plain = try #require(session.previewImage(fitting: viewSize))
        session.addLocal(.subject)
        await session.masksSettled()
        session.adjustments.locals[0].settings.exposure = 2
        #expect(session.canPaintSelectedMask)

        session.beginStroke(at: .init(x: 0.5, y: 0.5))
        for step in 1...20 { session.continueStroke(to: .init(x: 0.5 + Double(step) * 0.01, y: 0.5)) }
        session.endStroke()

        guard case .detected(let mask) = session.adjustments.locals.first?.mask else {
            Issue.record("painting replaced the found mask instead of correcting it")
            return
        }
        #expect(mask.corrections.strokes.count == 1, "one stroke, however many points")
        #expect(mask.subject == .subject, "the layer is still the one the machine fills")

        // What was painted lightens the middle, whether or not Vision found anything.
        let painted = try #require(session.previewImage(fitting: viewSize))
        let middle = CGRect(x: painted.extent.midX - 10, y: painted.extent.midY - 10, width: 20, height: 20)
        #expect(try probe.average(of: painted, in: middle).luminance > probe.average(of: plain, in: middle).luminance + 0.05)
    }

    /// A stroke on a found mask is one undo step, like every other stroke.
    @Test func correctingIsOneUndoStep() async throws {
        session.addLocal(.subject)
        await session.masksSettled()
        session.beginStroke(at: .init(x: 0.4, y: 0.4))
        session.continueStroke(to: .init(x: 0.6, y: 0.4))
        session.endStroke()
        session.undo()
        guard case .detected(let mask) = session.adjustments.locals.first?.mask else {
            Issue.record("undo removed more than the stroke")
            return
        }
        #expect(mask.corrections.strokes.isEmpty)
    }

    /// The pixels never reach the sidecar: what is written is the sort and the instance.
    @Test func whatIsSavedIsWhatWasAskedFor() async throws {
        session.addLocal(.subject)
        await session.masksSettled()
        let json = try session.adjustments.jsonData()
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"detected\"") && text.contains("\"subject\""))
        let decoded = try JSONDecoder().decode(Adjustments.self, from: json)
        #expect(decoded == session.adjustments)
    }
}

/// Choosing between what the machine found: the second person in the frame rather than the
/// first. The model always carried the instance; until now nothing could ask for another one.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DetectedInstanceTests {
    let session = DevelopSession()

    init() throws {
        MaskRasterStore.shared.removeAll()
        session.maskCache = MaskRasterCache(folder: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        session.open(TestPhoto.url)
    }

    @Test func choosingAnotherInstanceKeepsWhatWasPaintedAndAsksAgain() throws {
        session.addLocal(.person)
        guard case .detected(var mask)? = session.adjustments.locals.first?.mask else {
            Issue.record("no found mask")
            return
        }
        mask.corrections = BrushMask(strokes: [.init(points: [.init(x: 0.4, y: 0.4)], radius: 0.05)])
        session.updateSelectedMask(.detected(mask))

        session.chooseInstance(1, of: mask)

        guard case .detected(let now)? = session.adjustments.locals.first?.mask else {
            Issue.record("the layer lost its mask")
            return
        }
        #expect(now.instance == 1)
        // A new identity, so the picture of the old shape is not shown for the new one.
        #expect(now.id != mask.id)
        #expect(now.corrections.strokes.count == 1)
        // No picture yet means a black mask, which changes nothing: the photo does not flicker.
        #expect(!session.hasRaster(for: now))
    }

    @Test func askingForTheOneAlreadyChosenChangesNothing() throws {
        session.addLocal(.subject)
        guard case .detected(let mask)? = session.adjustments.locals.first?.mask else { return }
        session.chooseInstance(0, of: mask)
        guard case .detected(let now)? = session.adjustments.locals.first?.mask else { return }
        #expect(now.id == mask.id)
    }
}
