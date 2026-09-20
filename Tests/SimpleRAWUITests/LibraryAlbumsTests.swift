import Catalog
import Foundation
import RawEngine
import Testing
@testable import SimpleRAWUI

@MainActor
@Suite struct LibraryAlbumsTests {
    let sandbox: LibrarySandbox
    var session: LibrarySession { sandbox.session }

    init() throws {
        sandbox = try LibrarySandbox()
    }

    @Test func anAlbumCanBeRenamed() throws {
        defer { sandbox.cleanUp() }
        session.createAlbum(named: "Trip")
        let album = try #require(session.albums.first)
        session.renameAlbum(album.id, to: "  Lille 2026 ")
        #expect(session.albums.map(\.name) == ["Lille 2026"])
        // An empty name is no name: the album keeps its own.
        session.renameAlbum(album.id, to: "   ")
        #expect(session.albums.map(\.name) == ["Lille 2026"])
    }

    /// Dragging a thumbnail of the selection drags the selection; any other one goes alone.
    @Test func whatIsDraggedDependsOnTheSelection() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[0])
        session.select(ids[2], toggling: true)
        #expect(session.draggedPhotos(from: ids[2]) == [ids[0], ids[2]])
        #expect(session.draggedPhotos(from: ids[4]) == [ids[4]])
    }

    @Test func photosDroppedOnAnAlbumJoinIt() async throws {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.createAlbum(named: "Trip")
        let album = try #require(session.albums.first)
        session.add([ids[1], ids[3]], toAlbum: album.id)
        #expect(session.notice == "2 photos added to “Trip”.")
        session.source = .album(album.id)
        await session.settle()
        #expect(Set(session.photos.map(\.id)) == [ids[1], ids[3]])
    }

    /// The purple label had no key and no menu: it could be filtered on, never set.
    @Test func aLabelIsSetFromAMenuAndTakenOff() {
        defer { sandbox.cleanUp() }
        session.select(session.photos[0].id)
        session.setColorLabel(.purple)
        #expect(session.photos[0].colorLabel == .purple)
        session.setColorLabel(nil)
        #expect(session.photos[0].colorLabel == nil)
        session.setColorLabel(nil)
        #expect(session.photos[0].colorLabel == nil)
    }
}

@MainActor
@Suite struct LibraryRemovalTests {
    let sandbox: LibrarySandbox
    let session: LibrarySession

    init() throws {
        sandbox = try LibrarySandbox()
        // Records point to no file, and nothing here may reach the Trash.
        session = LibrarySession(library: sandbox.library) { _ in }
    }

    @Test func removingAsksFirstAndSaysHowMany() async {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.requestRemovalOfSelection()
        #expect(session.removalRequest == nil)

        session.select(ids[0])
        session.requestRemovalOfSelection()
        #expect(session.removalRequest?.title == "Remove 1 photo from the library?")
        session.cancelRemoval()
        #expect(session.removalRequest == nil)
        await session.settle()
        #expect(session.photos.count == 5)

        session.requestRemovalOfSelection()
        session.confirmRemoval()
        await session.settle()
        #expect(session.removalRequest == nil)
        #expect(session.photos.map(\.id) == Array(ids.dropFirst()) && session.totalCount == 4)
    }

    /// Culling ends with one command, not with filter, select all, right-click, remove.
    @Test func rejectedPhotosAreRemovedInOneCommand() async {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[1])
        session.select(ids[3], toggling: true)
        session.setFlag(.rejected)
        session.select(ids[0])
        // Whatever the filter bar shows: the command is about the source.
        session.filter.minimumRating = 5
        await session.settle()

        session.requestRemovalOfRejected()
        await session.settle()
        #expect(session.removalRequest?.title == "Remove 2 rejected photos from the library?")
        session.confirmRemoval()
        session.clearFilter()
        await session.settle()
        #expect(session.photos.map(\.id) == [ids[0], ids[2], ids[4]])
    }

    @Test func withNothingRejectedThereIsNothingToConfirm() async {
        defer { sandbox.cleanUp() }
        session.requestRemovalOfRejected()
        await session.settle()
        #expect(session.removalRequest == nil)
        #expect(session.notice == "No photo is rejected here.")
    }
}

/// The library in time: at twenty thousand photos, albums and keywords no longer say where
/// a shoot is.
@MainActor
@Suite struct LibraryByDateTests {
    @Test func theSidebarListsTheMonthsAndStandingInOneNarrowsTheGrid() async throws {
        let sandbox = try LibrarySandbox(photos: 5)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        await session.settle()

        // The sandbox shoots one photo a day from 1970-01-02: all in the same month.
        let month = try #require(session.months.first)
        #expect(month.count == 5 && session.months.count == 1)
        #expect(MonthName.of(month) == "January 1970")

        session.source = session.monthSource(month)
        await session.settle()
        #expect(session.photos.count == 5)

        session.source = .month(year: 2001, month: 3)
        await session.settle()
        #expect(session.photos.isEmpty, "a month the library has nothing in shows nothing")
    }

    /// A month whose photos are all removed is no longer somewhere to stand.
    @Test func anEmptiedMonthGivesTheGridBack() async throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        await session.settle()
        session.source = session.monthSource(try #require(session.months.first))
        await session.settle()

        session.selectAll()
        session.removeSelectionFromLibrary()
        session.confirmRemoval()
        await session.settle()
        #expect(session.source == .allPhotos && session.months.isEmpty)
    }
}
