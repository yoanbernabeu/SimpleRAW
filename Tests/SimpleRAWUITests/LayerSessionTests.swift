import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

@MainActor
@Suite
struct LayerSessionTests {
    let session = DevelopSession()

    init() throws {
        session.open(TestPhoto.url)
    }

    @Test func layersAreListedTopFirstWithTheirNames() {
        session.addLocal(.linear)
        session.addLocal(.brush)
        #expect(session.layers.map(\.name) == ["Brush 1", "Gradient 1"])
    }

    @Test func aLayerCanBeHiddenFadedAndRenamedWithoutSelectingIt() throws {
        session.addLocal(.linear)
        session.addLocal(.brush)
        let bottom = try #require(session.layers.last)
        session.setLayer(bottom.id, enabled: false)
        session.setLayer(bottom.id, opacity: 30)
        session.renameLayer(bottom.id, to: "  Sky  ")

        let layer = session.adjustments.locals[0]
        #expect(!layer.isEnabled && layer.opacity == 30 && layer.name == "Sky")
        // The layer above is untouched, and still the selected one.
        #expect(session.adjustments.locals[1].isEnabled && session.selectedLocalID == session.adjustments.locals[1].id)
    }

    @Test func aBlankNameGoesBackToTheDefaultOne() throws {
        session.addLocal(.brush)
        let id = try #require(session.selectedLocalID)
        session.renameLayer(id, to: "Face")
        session.renameLayer(id, to: "   ")
        #expect(session.layers.first?.name == "Brush 1")
    }

    @Test func deletingALayerLeavesTheOthersAlone() throws {
        session.addLocal(.linear)
        session.addLocal(.radial)
        session.addLocal(.brush)
        let middle = session.adjustments.locals[1]
        session.adjustments.locals[2].settings.exposure = 1
        session.removeLayer(middle.id)
        #expect(session.adjustments.locals.map(\.mask.kind) == [.linear, .brush])
        #expect(session.adjustments.locals[1].settings.exposure == 1)
    }

    @Test func layersMoveUpAndDown() throws {
        session.addLocal(.linear)
        session.addLocal(.brush)
        let gradient = session.adjustments.locals[0].id
        session.moveLayer(gradient, up: true)
        #expect(session.layers.first?.id == gradient)
        #expect(!session.canMoveLayer(gradient, up: true) && session.canMoveLayer(gradient, up: false))
    }

    @Test func duplicatingSelectsTheCopy() throws {
        session.addLocal(.radial)
        let original = try #require(session.selectedLocalID)
        session.duplicateLayer(original)
        #expect(session.adjustments.locals.count == 2)
        #expect(session.selectedLocalID != original)
        #expect(session.layers.first?.name == "Radial 1 copy")
    }
}

/// The graduated filter that spares the steeple: a layer can be held to a range of tones.
@MainActor
@Suite
struct LuminanceRangeSessionTests {
    let session = DevelopSession()

    init() throws {
        session.open(TestPhoto.url)
        session.addLocal(.linear)
    }

    @Test func aLayerStartsOnEveryToneAndTheRangeIsOffUntilItIsNarrowed() throws {
        #expect(!session.limitsSelectedLayerToTones)
        #expect(session.selectedLuminanceRange == LuminanceRange())
        #expect(session.selectedLocal?.luminanceRange == nil, "a whole range is stored as none")
    }

    @Test func turningTheRangeOnStartsOnTheBrightHalf() throws {
        session.limitsSelectedLayerToTones = true
        let range = try #require(session.selectedLocal?.luminanceRange)
        #expect(range.lower == 0.5 && range.upper == 1)
        #expect(session.selectedLuminanceRange == range)

        session.limitsSelectedLayerToTones = false
        #expect(session.selectedLocal?.luminanceRange == nil)
    }

    /// Dragged like any slider: one undo step when it settles, not one per value.
    @Test func theBoundsAreDraggedAndUndoAtOnce() throws {
        session.limitsSelectedLayerToTones = true
        session.commitEdit()
        for lower in [0.45, 0.4, 0.3, 0.2] {
            session.setSelectedLuminanceRange(LuminanceRange(lower: lower, upper: 0.9, softness: 0.2))
        }
        session.commitEdit()
        #expect(session.selectedLuminanceRange.lower == 0.2 && session.selectedLuminanceRange.softness == 0.2)

        session.undo()
        #expect(session.selectedLuminanceRange == LuminanceRange(lower: 0.5, upper: 1))
    }

    /// Hostile or crossed values never reach the document: the engine's own rule, applied
    /// where the slider writes.
    @Test func crossedBoundsAreStraightenedOut() throws {
        session.limitsSelectedLayerToTones = true
        session.setSelectedLuminanceRange(LuminanceRange(lower: 0.8, upper: 0.3, softness: .nan))
        let range = try #require(session.selectedLocal?.luminanceRange)
        #expect(range.lower == 0.3 && range.upper == 0.8 && range.softness == LuminanceRange().softness)
    }

    /// The ramp drawn under the sliders: what the layer is worth on each tone, left to right.
    @Test func theRampFollowsTheRange() {
        session.limitsSelectedLayerToTones = true
        session.setSelectedLuminanceRange(LuminanceRange(lower: 0.5, upper: 1, softness: 0.1))
        let ramp = session.luminanceRampSamples(count: 5)
        #expect(ramp.count == 5)
        #expect(ramp.first == 0 && ramp.last == 1)
        #expect(ramp[2] > 0.4 && ramp[2] < 0.6, "half in at the lower bound")
    }

    @Test func withoutALayerSelectedThereIsNothingToLimit() {
        session.selectedLocalID = nil
        session.limitsSelectedLayerToTones = true
        #expect(session.adjustments.locals.allSatisfy { $0.luminanceRange == nil })
    }
}

@MainActor
@Suite
struct UndoTests {
    let session = DevelopSession()

    init() throws {
        session.open(TestPhoto.url)
    }

    @Test func nothingToUndoOnAFreshPhoto() {
        #expect(!session.canUndo && !session.canRedo)
    }

    @Test func undoAndRedoWalkThroughTheEdits() {
        session.adjustments.contrast = 20
        session.commitEdit()
        session.adjustments.shadows = 30
        session.commitEdit()

        session.undo()
        #expect(session.adjustments.contrast == 20 && session.adjustments.shadows == 0)
        session.undo()
        #expect(session.adjustments == Adjustments())
        #expect(!session.canUndo && session.canRedo)

        session.redo()
        session.redo()
        #expect(session.adjustments.shadows == 30 && !session.canRedo)
    }

    /// Dragging a slider changes the document dozens of times; it is one step to undo.
    @Test func aSliderDragIsOneStep() {
        for value in stride(from: 1.0, through: 40, by: 1) { session.adjustments.contrast = value }
        session.commitEdit()
        session.undo()
        #expect(session.adjustments.contrast == 0)
        #expect(!session.canUndo)
    }

    @Test func aNewEditDropsWhatCouldBeRedone() {
        session.adjustments.contrast = 20
        session.commitEdit()
        session.undo()
        session.adjustments.vibrance = 10
        session.commitEdit()
        #expect(!session.canRedo)
    }

    @Test func committingWithoutAChangeAddsNoStep() {
        session.commitEdit()
        session.commitEdit()
        #expect(!session.canUndo)
    }

    @Test func discreteActionsAreUndoableOnTheirOwn() {
        session.addLocal(.linear)
        session.addLocal(.brush)
        session.undo()
        #expect(session.adjustments.locals.count == 1)
        session.reset()
        session.undo()
        #expect(session.adjustments.locals.count == 1)
    }

    /// A button pressed right after a drag, or twice in a row, is a step of its own: it must
    /// not merge with whatever was still settling.
    @Test func geometryButtonsAreStepsOfTheirOwn() {
        session.adjustments.contrast = 20
        session.turn(clockwise: true)
        session.turn(clockwise: true)
        #expect(session.adjustments.geometry.quarterTurns == 2)
        session.undo()
        #expect(session.adjustments.geometry.quarterTurns == 1)
        session.undo()
        #expect(session.adjustments.geometry.quarterTurns == 0 && session.adjustments.contrast == 20)

        session.adjustments.geometry.straighten = 3
        session.apply(CropAspect.square)
        session.resetGeometry()
        #expect(session.adjustments.geometry == Geometry())
        session.undo()
        #expect(session.adjustments.geometry.crop != nil && session.adjustments.geometry.straighten == 3)
        session.undo()
        #expect(session.adjustments.geometry.crop == nil && session.adjustments.geometry.straighten == 3)
    }

    /// A button resets what its own bar shows. The crop bar shows turns, straightening and the
    /// frame; the keystone correction is a lens correction, with its own panel and its own
    /// reset, and a photographer who reframes a corrected building keeps the correction.
    @Test func resettingTheCropLeavesTheKeystoneCorrectionAlone() {
        session.adjustments.geometry.perspective = Perspective(vertical: 40)
        session.adjustments.geometry.straighten = 3
        session.apply(CropAspect.square)
        session.resetGeometry()
        #expect(session.adjustments.geometry.perspective == Perspective(vertical: 40))
        #expect(session.adjustments.geometry.straighten == 0 && session.adjustments.geometry.crop == nil)
    }

    /// Drawing a line along a sloping horizon straightens the picture by what it asks for,
    /// as one undo step, and puts the level down again.
    @Test func drawingALineStraightensThePicture() {
        session.adjustments.contrast = 20
        session.tool = .level
        // 200 px along, 200 px down: a horizon falling at 45°.
        session.level(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 300))
        #expect(abs(session.adjustments.geometry.straighten - -45) < 1e-9)
        #expect(session.tool == .crop, "the level is put down once the line is drawn")

        session.undo()
        #expect(session.adjustments.geometry.straighten == 0 && session.adjustments.contrast == 20)
    }

    /// A click is not a direction, and the level is put down all the same.
    @Test func aLineTooShortChangesNothing() {
        session.adjustments.geometry.straighten = 3
        session.tool = .level
        session.level(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 103, y: 101))
        #expect(session.adjustments.geometry.straighten == 3 && session.tool == .crop)
    }

    /// The line is drawn on the picture as it stands, so what it asks for adds to what is there.
    @Test func whatTheLineAsksForAddsToTheStraighteningAlreadyThere() {
        session.adjustments.geometry.straighten = 5
        session.tool = .level
        let fall = 200 * tan(10 * Double.pi / 180)
        session.level(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 200, y: 100 + fall))
        #expect(abs(session.adjustments.geometry.straighten - -5) < 1e-6)
    }

    /// X in the crop tool: the locked ratio goes from landscape to portrait, as one step.
    @Test func turningTheRatioRecropsAndCanBeUndone() throws {
        session.apply(CropAspect.fiveByFour)
        let frame = try #require(session.cropFrameSize)
        let landscape = try #require(session.adjustments.geometry.crop)
        #expect(landscape.width * frame.width > landscape.height * frame.height)

        session.turnCropAspect()
        let portrait = try #require(session.adjustments.geometry.crop)
        #expect(portrait.width * frame.width < portrait.height * frame.height)
        #expect(session.cropAspectIsTurned)

        session.undo()
        #expect(session.adjustments.geometry.crop == landscape)
    }

    /// The history can be read, and any step of it gone back to: not only undone blindly.
    @Test func theHistoryNamesItsStepsAndGoesBackToAnyOfThem() throws {
        session.adjustments.exposure = 0.5
        session.commitEdit()
        session.apply(try #require(session.presets.first { $0.name == "Black & white" }))
        session.turn(clockwise: true)
        #expect(session.historySteps.map(\.label) == ["Opened", "Exposure +0.50", "Look: Black & white", "Rotate"])
        #expect(session.historyCursor == 3)

        session.goToHistoryStep(1)
        #expect(session.adjustments.exposure == 0.5 && !session.adjustments.blackAndWhite.isEnabled)
        #expect(session.adjustments.geometry.quarterTurns == 0)
        #expect(session.historyCursor == 1 && session.historySteps.count == 4, "what follows can still be gone to")

        session.goToHistoryStep(3)
        #expect(session.adjustments.blackAndWhite.isEnabled && session.adjustments.geometry.quarterTurns == 1)
    }

    @Test func historyBelongsToOnePhoto() throws {
        session.adjustments.contrast = 20
        session.commitEdit()
        session.open(TestPhoto.all[1])
        #expect(!session.canUndo)
    }
}

@MainActor
@Suite
struct AutoToneSessionTests {
    let session = DevelopSession()

    init() throws {
        session.open(TestPhoto.url)
    }

    @Test func autoIsOneUndoableStepThatLeavesOtherSettingsAlone() {
        session.adjustments.clarity = 25
        session.commitEdit()
        session.autoTone()
        #expect(session.adjustments.clarity == 25)
        #expect(session.adjustments != Adjustments())
        session.undo()
        #expect(session.adjustments.clarity == 25 && session.adjustments.exposure == 0 && session.adjustments.shadows == 0)
    }

    /// Auto looks at the picture, not at the sliders: running it twice changes nothing more.
    @Test func autoDoesNotCompound() {
        session.autoTone()
        let first = session.adjustments
        session.autoTone()
        #expect(session.adjustments == first)
    }
}

@MainActor
@Suite
struct WhiteBalanceSessionTests {
    let session = DevelopSession()

    init() throws {
        session.open(TestPhoto.all[1])
    }

    /// Only sensor data can say what is neutral: this one needs a RAW file.
    @Test(.enabled(if: Sample.url != nil, "No DNG in Samples/"))
    func clickingWithTheEyedropperSetsTheWhiteBalanceAndPutsItDown() throws {
        session.open(try #require(Sample.all.last))
        session.tool = .whiteBalance
        session.pickWhiteBalance(at: NormalizedPoint(x: 0.88, y: 0.5))
        #expect(session.adjustments.whiteBalance != nil)
        #expect(session.tool == .none)
        session.undo()
        #expect(session.adjustments.whiteBalance == nil)
    }

    /// The point clicked is a point of the sensor: the eyedropper shows the original frame.
    @Test func theEyedropperShowsTheOriginalFrame() throws {
        session.adjustments.geometry.quarterTurns = 1
        session.tool = .whiteBalance
        let shown = try #require(session.previewImage(fitting: CGSize(width: 750, height: 500))).extent.size
        #expect(shown.width > shown.height)
    }

    @Test func aPresetIsOneUndoStep() {
        session.apply(WhiteBalancePreset.cloudy)
        #expect(session.adjustments.whiteBalance == WhiteBalancePreset.cloudy.whiteBalance)
        #expect(session.whiteBalancePreset == .cloudy)
        session.undo()
        #expect(session.whiteBalancePreset == .asShot)
    }
}

@MainActor
@Suite
struct ClippingSessionTests {
    @Test func burntAreasShowInRedOnThePictureAndNeverInAnExport() async throws {
        let session = DevelopSession()
        session.open(TestPhoto.url)
        session.adjustments.exposure = 4
        let view = CGSize(width: 750, height: 500)
        let probe = PixelProbe()
        let plain = try probe.average(of: try #require(session.previewImage(fitting: view)))
        session.showsClipping = true
        let marked = try probe.average(of: try #require(session.previewImage(fitting: view)))
        #expect(marked.g < plain.g * 0.7 && marked.r > 0.5)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-clip-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }
        var options = ExportOptions()
        options.longEdge = 300
        try await session.export(to: destination, options: options)
        let exported = try probe.average(of: try #require(CIImage(contentsOf: destination)))
        #expect(exported.g > 0.5)
    }
}
