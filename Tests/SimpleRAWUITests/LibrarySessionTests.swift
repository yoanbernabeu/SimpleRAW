import Catalog
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// A library in a throwaway folder, filled with records that point to no real file: what is
/// tested here is the state of the library window, not decoding.
@MainActor
struct LibrarySandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-libsession-\(UUID().uuidString)")
    let library: Library
    let session: LibrarySession

    init(photos: Int = 5) throws {
        library = try Library(root: root)
        for index in 1...photos {
            try library.catalog.add(NewPhoto(
                relativePath: "Originals/2026/2026-09-1\(index)/R000\(index).DNG", fileName: "R000\(index).DNG",
                contentHash: "hash\(index)", captureDate: Date(timeIntervalSince1970: Double(index) * 86_400),
                camera: "RICOH GR III", lens: nil, iso: 100 * index, exposureTime: 0.01, aperture: 5.6, focalLength: 18.3,
                width: 6000, height: 4000
            ))
        }
        session = LibrarySession(library: library)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
@Suite struct LibrarySessionTests {
    let sandbox: LibrarySandbox
    var session: LibrarySession { sandbox.session }

    init() throws {
        sandbox = try LibrarySandbox()
    }

    @Test func showsTheWholeLibraryNewestFirst() {
        defer { sandbox.cleanUp() }
        #expect(session.photos.map(\.fileName) == ["R0005.DNG", "R0004.DNG", "R0003.DNG", "R0002.DNG", "R0001.DNG"])
        #expect(session.source == .allPhotos)
    }

    // MARK: Selection

    @Test func aClickSelectsOnePhoto() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[1])
        session.select(ids[3])
        #expect(session.selection == [ids[3]])
    }

    @Test func commandClickTogglesAndShiftClickExtends() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[1])
        session.select(ids[3], toggling: true)
        #expect(session.selection == [ids[1], ids[3]])
        session.select(ids[1], toggling: true)
        #expect(session.selection == [ids[3]])

        session.select(ids[0])
        session.select(ids[2], extending: true)
        #expect(session.selection == [ids[0], ids[1], ids[2]])
    }

    @Test func arrowKeysMoveTheSelectionAndStopAtTheEnds() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.moveSelection(by: 1)
        #expect(session.selection == [ids[0]])
        session.moveSelection(by: 1)
        session.moveSelection(by: -5)
        #expect(session.selection == [ids[0]])
        session.moveSelection(by: 99)
        #expect(session.selection == [ids[4]])
    }

    @Test func selectAllAndNone() {
        defer { sandbox.cleanUp() }
        session.selectAll()
        #expect(session.selection.count == 5)
        session.deselectAll()
        #expect(session.selection.isEmpty)
    }

    // MARK: Rating, flags, labels

    @Test func ratingAppliesToTheSelectionAndShowsAtOnce() throws {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.select(ids[1], toggling: true)
        session.setRating(4)
        #expect(session.photos.prefix(3).map(\.rating) == [4, 4, 0])
        #expect(try sandbox.library.catalog.photo(ids[0])?.rating == 4)
    }

    /// Rating with the keyboard is the fastest gesture of a cull: it must not read the whole
    /// library back from disk every time.
    @Test func ratingUpdatesTheGridInPlace() throws {
        defer { sandbox.cleanUp() }
        let reloads = session.reloadCount
        session.select(session.photos[2].id)
        session.setRating(3)
        session.setFlag(.picked)
        session.setColorLabel(.blue)
        #expect(session.reloadCount == reloads)
        #expect(session.photos[2].rating == 3 && session.photos[2].flag == .picked && session.photos[2].colorLabel == .blue)
        #expect(try sandbox.library.catalog.photo(session.photos[2].id)?.rating == 3)
    }

    /// Unless the change can move a photo in or out of what is shown.
    @Test func aChangeTheFilterOrTheSortDependsOnStillRefreshesTheGrid() async {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.selectAll()
        session.setRating(4)
        session.filter.minimumRating = 3
        session.select(ids[0])
        session.setRating(1)
        await session.settle()
        #expect(!session.photos.map(\.id).contains(ids[0]))

        session.filter = PhotoFilter()
        session.sort = .rating
        await session.settle()
        session.select(ids[4])
        session.setRating(5)
        await session.settle()
        #expect(session.photos.first?.id == ids[4])
    }

    @Test func flagsAndLabelsToo() {
        defer { sandbox.cleanUp() }
        session.select(session.photos[0].id)
        session.setFlag(.picked)
        session.setColorLabel(.green)
        #expect(session.photos[0].flag == .picked && session.photos[0].colorLabel == .green)
        // The same label again clears it, like a toggle.
        session.setColorLabel(.green)
        #expect(session.photos[0].colorLabel == nil)
    }

    // MARK: Filtering

    @Test func theFilterNarrowsTheGridAndDropsHiddenPhotosFromTheSelection() async {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.setRating(5)
        session.selectAll()
        session.filter.minimumRating = 3
        await session.settle()
        #expect(session.photos.map(\.id) == [ids[0]])
        #expect(session.selection == [ids[0]])
    }

    @Test func choosingTheSourceAlreadyShownReadsNothing() {
        defer { sandbox.cleanUp() }
        let reloads = session.reloadCount
        session.source = .allPhotos
        #expect(session.reloadCount == reloads)
    }

    @Test func albumsAreSourcesOfTheirOwn() async throws {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.select(ids[1], toggling: true)
        session.createAlbum(named: "Trip", fromSelection: true)
        let album = try #require(session.albums.first)
        session.source = .album(album.id)
        await session.settle()
        #expect(Set(session.photos.map(\.id)) == [ids[0], ids[1]])
        // The filter bar still applies inside an album.
        session.filter.minimumRating = 1
        await session.settle()
        #expect(session.photos.isEmpty)
    }

    @Test func aSmartAlbumIsTheCurrentFilterSaved() async throws {
        defer { sandbox.cleanUp() }
        session.select(session.photos[0].id)
        session.setRating(5)
        session.filter.minimumRating = 5
        session.saveFilterAsSmartAlbum(named: "Best")
        session.filter = PhotoFilter()
        let album = try #require(session.smartAlbums.first)
        session.source = .smartAlbum(album.id)
        await session.settle()
        #expect(session.photos.count == 1)
    }

    // MARK: Settings across photos

    @Test func aLookAppliesToEverySelectedPhoto() async throws {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.select(ids[2], toggling: true)
        var look = Adjustments()
        look.contrast = 20
        session.apply(Preset(name: "Look", capturing: look, groups: [.light]))
        await session.settle()
        #expect(session.photos.map { $0.adjustments.contrast } == [20, 0, 20, 0, 0])
        #expect(session.photos[0].isEdited)
    }
}

@MainActor
@Suite struct LibraryUndoTests {
    /// A look applied to forty photos by mistake used to be there for good.
    @Test func aLookAppliedToASelectionCanBeUndone() async throws {
        let sandbox = try LibrarySandbox(photos: 3)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        let ids = session.photos.map(\.id)
        var own = Adjustments()
        own.shadows = 12
        try sandbox.library.catalog.setAdjustments(own, for: ids[1])
        session.reload()
        await session.settle()
        #expect(!session.canUndoLastChange)

        session.selectAll()
        var look = Adjustments()
        look.contrast = 30
        look.shadows = 50
        session.apply(Preset(name: "Look", capturing: look, groups: [.light]))
        await session.settle()
        #expect(session.canUndoLastChange && session.photos.allSatisfy { $0.adjustments.contrast == 30 })

        session.undoLastChange()
        await session.settle()
        #expect(session.photos.map { $0.adjustments.contrast } == [0, 0, 0])
        // Each photo gets back what it had, not a blank.
        #expect(session.photos.first { $0.id == ids[1] }?.adjustments.shadows == 12)
        #expect(!session.canUndoLastChange)
    }

    @Test func theLookChosenForImportsIsRemembered() throws {
        let sandbox = try LibrarySandbox(photos: 1)
        defer { sandbox.cleanUp() }
        let defaults = UserDefaults(suiteName: "simpleraw-tests-\(UUID().uuidString)")!
        let session = LibrarySession(library: sandbox.library, defaults: defaults)
        #expect(session.importLookName == nil && session.importPreset(looks: Preset.builtIns).look == nil)

        session.importLookName = "Camera match"
        let relaunched = LibrarySession(library: sandbox.library, defaults: defaults)
        #expect(relaunched.importPreset(looks: Preset.builtIns).look?.name == "Camera match")
        // A look that was deleted since must not break imports.
        #expect(relaunched.importPreset(looks: []).look == nil)
    }
}

@MainActor
@Suite struct CatalogAdjustmentsStoreTests {
    @Test func adjustmentsOfALibraryPhotoAreKeptInTheCatalog() throws {
        let sandbox = try LibrarySandbox(photos: 1)
        defer { sandbox.cleanUp() }
        let photo = sandbox.session.photos[0]
        let store = CatalogAdjustmentsStore(library: sandbox.library)
        let url = sandbox.library.url(for: photo)
        #expect(try store.load(for: url) == nil)

        var adjustments = Adjustments()
        adjustments.shadows = 40
        try store.save(adjustments, for: url)
        #expect(try store.load(for: url) == adjustments)
        #expect(try sandbox.library.catalog.photo(photo.id)?.adjustments == adjustments)
        // No sidecar next to the original: the catalog is the only place.
        #expect(!FileManager.default.fileExists(atPath: SidecarStore().sidecarURL(for: url).path))
    }

    @Test func aFileOutsideTheLibraryFallsBackToASidecar() throws {
        let sandbox = try LibrarySandbox(photos: 1)
        defer { sandbox.cleanUp() }
        let outside = sandbox.root.appendingPathComponent("elsewhere/photo.DNG")
        let store = CatalogAdjustmentsStore(library: sandbox.library, fallback: SidecarStore(directory: sandbox.root.appendingPathComponent("sidecars")))
        var adjustments = Adjustments()
        adjustments.contrast = 5
        try store.save(adjustments, for: outside)
        #expect(try store.load(for: outside) == adjustments)
    }
}
