import Catalog
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// A throwaway library with two real DNGs imported, to go from the grid to the develop view.
@MainActor
@Suite
struct AppSessionTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-app-\(UUID().uuidString)")
    let app: AppSession

    init() throws {
        let library = try Library(root: root)
        _ = Importer(library: library).run(Array(TestPhoto.all.prefix(2)))
        app = AppSession(library: library)
    }

    @Test func startsInTheLibrary() {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(app.mode == .library)
        #expect(app.library.photos.count == 2)
    }

    @Test func openingAPhotoShowsItInDevelop() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.open(photo)
        #expect(app.mode == .develop)
        #expect(app.develop.fileName == photo.fileName)
        #expect(app.library.selection == [photo.id])
    }

    @Test func editsAreInTheCatalogWhenComingBackToTheGrid() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.open(photo)
        app.develop.adjustments.contrast = 30
        app.showLibrary()

        #expect(app.mode == .library)
        let refreshed = try #require(app.library.photos.first { $0.id == photo.id })
        #expect(refreshed.isEdited && refreshed.adjustments.contrast == 30)
        // In the catalog, not in a sidecar next to the original.
        let sidecar = SidecarStore().sidecarURL(for: app.library.library.url(for: photo))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test func steppingGoesThroughTheGridInOrderAndKeepsEdits() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = app.library.photos
        app.open(photos[0])
        app.develop.adjustments.shadows = 25
        #expect(app.canStep(by: 1) && !app.canStep(by: -1))

        app.step(by: 1)
        #expect(app.develop.fileName == photos[1].fileName)
        #expect(app.develop.adjustments == Adjustments())
        #expect(!app.canStep(by: 1))

        app.step(by: -1)
        #expect(app.develop.adjustments.shadows == 25)
    }

    @Test func aFileFromOutsideTheLibraryStillOpens() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        app.openFile(TestPhoto.all[1])
        #expect(app.mode == .develop && app.develop.info != nil)
        #expect(!app.canStep(by: 1) && !app.canStep(by: -1))
    }

    /// The photo is fine, only its settings are not: it opens, and says so.
    @Test func aPhotoWhoseSettingsCannotBeReadStillOpens() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        try app.library.library.catalog.database.execute(
            "UPDATE photos SET adjustments = ?, is_edited = 1 WHERE id = ?", [.text("{ not json"), .int(photo.id)]
        )
        app.open(photo)
        #expect(app.mode == .develop)
        #expect(app.develop.fileName == photo.fileName)
        #expect(app.canStep(by: 1))
    }

    /// A bad file must not pass the photo that was open for the one that was asked for.
    @Test func aFileThatCannotBeOpenedChangesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.open(photo)
        app.showLibrary()
        let notAPhoto = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notAPhoto)

        app.openFile(notAPhoto)
        #expect(app.mode == .library)
        #expect(app.develop.errorMessage != nil)
        #expect(app.canStep(by: 1), "the open photo is still the library's")
    }

    // MARK: - Commands

    /// Purple has no key: the Photo menu sets it, and takes any label off.
    @Test func theMenuSetsAnyLabelAndTakesItOff() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.open(photo)
        app.perform(.label(.purple))
        #expect(app.library.photos.first { $0.id == photo.id }?.colorLabel == .purple)
        app.perform(.label(nil))
        #expect(app.library.photos.first { $0.id == photo.id }?.colorLabel == nil)
    }

    /// Culling without leaving the picture: what the photographer's review asked for first.
    @Test func ratingInDevelopRatesTheOpenPhoto() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = app.library.photos[0]
        app.open(photo)
        app.perform(.rate(4, advance: false))
        app.perform(.flag(.picked, advance: false))
        app.perform(.label(.green))
        let rated = try #require(app.library.photos.first { $0.id == photo.id })
        #expect(rated.rating == 4 && rated.flag == .picked && rated.colorLabel == .green)
        #expect(app.mode == .develop && app.develop.fileName == photo.fileName)
    }

    @Test func ratingWithAdvanceBringsUpTheNextPhoto() {
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = app.library.photos
        app.open(photos[0])
        app.perform(.flag(.rejected, advance: true))
        #expect(app.develop.fileName == photos[1].fileName)
        #expect(app.library.photos[0].flag == .rejected)
        // On the last photo there is nowhere to go: the rating still applies.
        app.perform(.rate(5, advance: true))
        #expect(app.develop.fileName == photos[1].fileName && app.library.photos[1].rating == 5)
    }

    @Test func inTheGridCommandsApplyToTheSelection() {
        defer { try? FileManager.default.removeItem(at: root) }
        app.library.select(app.library.photos[0].id)
        app.perform(.rate(3, advance: true))
        #expect(app.library.photos[0].rating == 3)
        #expect(app.library.selection == [app.library.photos[1].id])
    }

    /// Culling in the loupe: Shift and a rating move on to the next photo, Return develops it.
    @Test func theLoupeCullsAndOpensWhatItShows() {
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = app.library.photos
        app.library.select(photos[0].id)
        app.perform(.toggleLoupe)
        app.perform(.rate(4, advance: true))
        #expect(app.library.photos[0].rating == 4)
        #expect(app.library.loupePhoto?.id == photos[1].id)
        app.perform(.moveSelection(.left))
        #expect(app.library.loupePhoto?.id == photos[0].id)

        app.perform(.openSelection)
        #expect(app.mode == .develop && app.develop.fileName == photos[0].fileName)
        #expect(!app.library.isLoupeOpen)
    }

    @Test func libraryCommands() {
        defer { try? FileManager.default.removeItem(at: root) }
        app.perform(.selectAll)
        #expect(app.library.selection.count == 2)
        app.perform(.toggleLoupe)
        app.perform(.closeLoupe)
        #expect(!app.library.isLoupeOpen)
    }

    /// Regression: Escape validated a crop. It must give it up.
    @Test func cancellingTheCropToolRestoresTheFraming() {
        defer { try? FileManager.default.removeItem(at: root) }
        app.open(app.library.photos[0])
        app.develop.adjustments.geometry.straighten = 2
        app.perform(.setTool(.crop))
        app.develop.adjustments.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        app.develop.adjustments.geometry.straighten = 9
        app.perform(.cancelTool)
        #expect(app.develop.tool == .none)
        #expect(app.develop.adjustments.geometry.crop == nil && app.develop.adjustments.geometry.straighten == 2)
    }

    @Test func leavingTheCropToolNormallyKeepsTheFraming() {
        defer { try? FileManager.default.removeItem(at: root) }
        app.open(app.library.photos[0])
        app.perform(.setTool(.crop))
        app.develop.adjustments.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        app.perform(.setTool(.none))
        #expect(app.develop.adjustments.geometry.crop != nil)
    }

    @Test func viewCommands() {
        defer { try? FileManager.default.removeItem(at: root) }
        app.open(app.library.photos[0])
        app.perform(.toggleOriginal)
        #expect(app.develop.showsOriginal)
        app.perform(.toggleZoom)
        #expect(app.develop.zoom != .fit)
        app.perform(.showLibrary)
        #expect(app.mode == .library)
    }

    // MARK: - The filmstrip

    /// Under the picture, the rest of the shoot: the way to the next frame without going
    /// back to the grid. Its thumbnails are the grid's, so the GPU is only asked for them
    /// while the strip is actually on screen.
    @Test func theFilmstripShowsTheGridAroundTheOpenPhoto() {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(app.filmstripPhotos.isEmpty, "nothing to show next to no photo")

        app.open(app.library.photos[0])
        #expect(app.filmstripPhotos.map(\.id) == app.library.photos.map(\.id))
        #expect(app.showsFilmstrip, "shown by default: it is how one moves through a shoot")
        #expect(!app.thumbnails.isSuspended)

        app.showsFilmstrip = false
        #expect(app.thumbnails.isSuspended, "hidden, the GPU goes back to the picture")
        app.showsFilmstrip = true
        #expect(!app.thumbnails.isSuspended)

        app.perform(.showLibrary)
        #expect(!app.thumbnails.isSuspended && app.filmstripPhotos.isEmpty)
    }

    @Test func aFileFromOutsideTheLibraryHasNoFilmstrip() {
        defer { try? FileManager.default.removeItem(at: root) }
        app.openFile(TestPhoto.all[1])
        #expect(app.filmstripPhotos.isEmpty)
        #expect(app.thumbnails.isSuspended, "nothing to decode for it")
    }

    @Test func clickingAFrameOpensIt() {
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = app.library.photos
        app.open(photos[0])
        app.develop.adjustments.contrast = 20

        app.open(photos[1])
        #expect(app.openPhotoID == photos[1].id && app.develop.adjustments == Adjustments())
        // The edits of the one being left are saved, as when stepping.
        app.open(photos[0])
        #expect(app.develop.adjustments.contrast == 20)
    }
}
