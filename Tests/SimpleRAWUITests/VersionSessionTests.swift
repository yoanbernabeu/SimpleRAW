import Catalog
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// The color version and the black and white one of the same photo, kept side by side.
@MainActor
@Suite struct VersionSessionTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-versions-\(UUID().uuidString)")
    let app: AppSession

    init() throws {
        let library = try Library(root: root)
        _ = Importer(library: library).run(Array(TestPhoto.all.prefix(2)))
        app = AppSession(library: library)
        app.open(app.library.photos[0])
    }

    @Test func aVersionIsSavedShownAgainAndOutlivesTheSession() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = app.develop
        #expect(session.canKeepVersions && session.versions.isEmpty)

        session.adjustments.vibrance = 30
        session.saveVersion(named: "Color")
        session.adjustments.blackAndWhite.isEnabled = true
        session.saveVersion(named: "Black & white")
        #expect(session.versions.map(\.name) == ["Color", "Black & white"])

        session.show(try #require(session.versions.first))
        #expect(!session.adjustments.blackAndWhite.isEnabled && session.adjustments.vibrance == 30)
        session.undo()
        #expect(session.adjustments.blackAndWhite.isEnabled, "showing a version is one undo step")

        app.step(by: 1)
        #expect(session.versions.isEmpty, "versions belong to one photo")
        app.step(by: -1)
        #expect(session.versions.map(\.name) == ["Color", "Black & white"])
    }

    @Test func theVersionOnScreenIsKnownAndVersionsCanBeRenamedAndDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = app.develop
        session.adjustments.contrast = 15
        session.saveVersion(named: "Punchy")
        let version = try #require(session.versions.first)
        #expect(session.isShown(version))
        session.adjustments.contrast = 0
        #expect(!session.isShown(version))

        session.renameVersion(version, to: "Contrast")
        #expect(session.versions.map(\.name) == ["Contrast"])
        session.deleteVersion(try #require(session.versions.first))
        #expect(session.versions.isEmpty)
    }

    // MARK: - The history outlives the session

    @Test func theHistoryIsThereAgainWhenThePhotoIsOpenedAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let session = app.develop
        session.adjustments.exposure = 0.5
        session.commitEdit()
        session.turn(clockwise: true)
        session.undo()
        let (steps, cursor) = (session.historySteps, session.historyCursor)
        #expect(steps.map(\.label) == ["Opened", "Exposure +0.50", "Rotate"] && cursor == 1)

        app.step(by: 1)
        #expect(session.historySteps.map(\.label) == ["Opened"])
        app.step(by: -1)
        #expect(session.historySteps == steps && session.historyCursor == cursor)
        session.goToHistoryStep(2)
        #expect(session.adjustments.geometry.quarterTurns == 1, "and its steps still hold their settings")
    }

    /// A look applied from the grid changed the photo behind the history's back: a history
    /// that no longer leads to the photo as it is would lie.
    @Test func aHistoryThatNoLongerMatchesThePhotoIsDropped() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.develop.adjustments.exposure = 0.5
        app.showLibrary()
        var changed = Adjustments()
        changed.contrast = 40
        try app.library.library.catalog.setAdjustments(changed, for: photo.id)

        app.open(photo)
        #expect(app.develop.adjustments.contrast == 40)
        #expect(app.develop.historySteps.map(\.label) == ["Opened"])
    }

    @Test func aFileFromOutsideTheLibraryKeepsNoVersions() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        app.openFile(TestPhoto.all[1])
        #expect(!app.develop.canKeepVersions)
        app.develop.saveVersion(named: "Nowhere")
        #expect(app.develop.versions.isEmpty && app.develop.errorMessage == nil)
    }
}
