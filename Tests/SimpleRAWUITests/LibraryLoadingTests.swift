import Catalog
import Foundation
import RawEngine
import Testing
@testable import SimpleRAWUI

/// The grid is read from the catalog off the main actor: nothing here may wait for a query.
@MainActor
@Suite struct LibraryLoadingTests {
    let sandbox: LibrarySandbox
    var session: LibrarySession { sandbox.session }

    init() throws {
        sandbox = try LibrarySandbox()
    }

    /// One query per character typed, the first of which matches nearly everything.
    @Test func theSearchWaitsForTypingToPause() async {
        defer { sandbox.cleanUp() }
        let reloads = session.reloadCount
        session.searchText = "R"
        session.searchText = "R00"
        session.searchText = "R0003"
        #expect(session.reloadCount == reloads && session.filter.text == nil)
        await session.settle()
        #expect(session.reloadCount == reloads + 1)
        #expect(session.filter.text == "R0003")
        #expect(session.photos.map(\.fileName) == ["R0003.DNG"])
    }

    @Test func clearingTheFilterEmptiesTheSearchFieldToo() async {
        defer { sandbox.cleanUp() }
        session.searchText = "R0003"
        session.filter.minimumRating = 2
        session.clearFilter()
        await session.settle()
        #expect(session.searchText.isEmpty && session.filter.isEmpty)
        #expect(session.photos.count == 5)
    }

    @Test func aChangeOfFilterDoesNotBlockAndShowsOnceRead() async {
        defer { sandbox.cleanUp() }
        session.select(session.photos[0].id)
        session.setRating(5)
        session.filter.minimumRating = 5
        #expect(session.photos.count == 5)
        await session.settle()
        #expect(session.photos.count == 1)
    }

    /// A slow answer to an old question must never replace the answer to the current one.
    @Test func onlyTheLastQuestionAskedIsAnswered() async {
        defer { sandbox.cleanUp() }
        let reads = session.readCount
        session.filter.minimumRating = 5
        session.sort = .fileName
        session.filter.minimumRating = 0
        await session.settle()
        #expect(session.photos.map(\.fileName) == ["R0001.DNG", "R0002.DNG", "R0003.DNG", "R0004.DNG", "R0005.DNG"])
        #expect(session.readCount == reads + 1)
    }

    @Test func theSelectionComesInTheOrderOfTheGrid() {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        session.select(ids[3])
        session.select(ids[1], toggling: true)
        session.select(ids[4], toggling: true)
        #expect(session.selectedPhotos.map(\.id) == [ids[1], ids[3], ids[4]])
    }

    /// Selecting must never wait for the keywords of what is selected.
    @Test func theKeywordsOfTheSelectionFollowIt() async throws {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        try sandbox.library.catalog.setKeywords(["street", "night"], for: ids[0])
        try sandbox.library.catalog.setKeywords(["street"], for: ids[1])
        session.select(ids[0])
        await session.settle()
        #expect(session.keywordText == "night, street")
        session.select(ids[1], toggling: true)
        await session.settle()
        #expect(session.keywordText == "street")
        session.deselectAll()
        #expect(session.keywordText.isEmpty)
    }

    /// An error while reading keywords used to read as "this photo has none".
    @Test func keywordsThatCannotBeReadAreAnErrorNotAnEmptyList() async throws {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        try sandbox.library.catalog.setKeywords(["street"], for: ids[0])
        try sandbox.library.catalog.database.execute("ALTER TABLE photo_keywords RENAME TO lost")
        #expect(throws: (any Error).self) { try session.keywords(for: ids[0]) }

        session.select(ids[0])
        session.setKeywords(fromText: "night")
        await session.settle()
        // Said in words, not as the dump of a Swift value.
        let message = try #require(session.errorMessage)
        #expect(message.contains("photo_keywords") && !message.contains("DatabaseError"))
        try sandbox.library.catalog.database.execute("ALTER TABLE lost RENAME TO photo_keywords")
        #expect(try session.keywords(for: ids[0]) == ["street"])
    }

    /// Back from the develop view, the photo that was open shows its edits at once; the rest
    /// of the grid is read again behind.
    @Test func thePhotoThatWasOpenShowsItsEditsAtOnce() async throws {
        defer { sandbox.cleanUp() }
        let ids = session.photos.map(\.id)
        var edits = Adjustments()
        edits.contrast = 25
        try sandbox.library.catalog.setAdjustments(edits, for: ids[2])
        try sandbox.library.catalog.setAdjustments(edits, for: ids[3])
        session.refresh(after: ids[2])
        #expect(session.photos[2].adjustments.contrast == 25 && session.photos[2].isEdited)
        // The row as the catalog holds it, fingerprint included: naming its thumbnail encodes nothing.
        #expect(session.photos[2] == (try sandbox.library.catalog.photo(ids[2])))
        await session.settle()
        #expect(session.photos[3].adjustments.contrast == 25)
    }

    @Test func aSmartAlbumIsReadFromMemoryAndNarrowedByTheBar() async throws {
        defer { sandbox.cleanUp() }
        session.selectAll()
        session.setRating(3)
        session.select(session.photos[0].id)
        session.setRating(5)
        session.filter.minimumRating = 3
        session.saveFilterAsSmartAlbum(named: "Good")
        session.clearFilter()
        session.source = .smartAlbum(try #require(session.smartAlbums.first).id)
        await session.settle()
        #expect(session.photos.count == 5)
        session.filter.minimumRating = 5
        await session.settle()
        #expect(session.photos.count == 1)
    }
}
