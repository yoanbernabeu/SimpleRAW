import Foundation
import RawEngine
import Testing
@testable import Catalog

@Suite struct PhotoFilterTests {
    let catalog: PhotoCatalog
    /// a: 2026-09-11, ISO 100, 5★ picked red, "street" + "Lille", edited
    /// b: 2026-09-16, ISO 400, 3★, "street"
    /// c: 2026-09-16, ISO 3200, 0★ rejected, no keyword, another camera
    let a: Int64, b: Int64, c: Int64

    init() throws {
        catalog = try PhotoCatalog.inMemory()
        a = try catalog.add(makePhoto("a.DNG", captured: "2026-09-11T11:14:40", iso: 100))
        b = try catalog.add(makePhoto("b.DNG", captured: "2026-09-16T16:59:39", iso: 400))
        var other = makePhoto("c.DNG", captured: "2026-09-16T18:15:38", iso: 3200)
        other.camera = "FUJIFILM X100V"
        c = try catalog.add(other)

        try catalog.setRating(5, for: [a])
        try catalog.setRating(3, for: [b])
        try catalog.setFlag(.picked, for: [a])
        try catalog.setFlag(.rejected, for: [c])
        try catalog.setColorLabel(.red, for: [a])
        try catalog.setKeywords(["street", "Lille"], for: a)
        try catalog.setKeywords(["street"], for: b)
        var edits = Adjustments()
        edits.contrast = 10
        try catalog.setAdjustments(edits, for: a)
    }

    private func names(_ filter: PhotoFilter, sort: PhotoSort = .captureDate(ascending: true)) throws -> [String] {
        try catalog.photos(matching: filter, sort: sort).map(\.fileName)
    }

    @Test func anEmptyFilterMatchesEverything() throws {
        #expect(try names(PhotoFilter()) == ["a.DNG", "b.DNG", "c.DNG"])
        #expect(try catalog.count(matching: PhotoFilter()) == 3)
    }

    @Test func filtersByMinimumRating() throws {
        #expect(try names(PhotoFilter(minimumRating: 3)) == ["a.DNG", "b.DNG"])
        #expect(try names(PhotoFilter(minimumRating: 4)) == ["a.DNG"])
    }

    @Test func filtersByFlagAndLabel() throws {
        #expect(try names(PhotoFilter(flags: [.picked])) == ["a.DNG"])
        #expect(try names(PhotoFilter(flags: [.none, .picked])) == ["a.DNG", "b.DNG"])
        #expect(try names(PhotoFilter(colorLabels: [.red, .blue])) == ["a.DNG"])
    }

    @Test func everyKeywordMustMatch() throws {
        #expect(try names(PhotoFilter(keywords: ["street"])) == ["a.DNG", "b.DNG"])
        #expect(try names(PhotoFilter(keywords: ["street", "lille"])) == ["a.DNG"])
        #expect(try names(PhotoFilter(keywords: ["nope"])).isEmpty)
    }

    @Test func textSearchesNamesCamerasKeywordsAndTitles() throws {
        #expect(try names(PhotoFilter(text: "fuji")) == ["c.DNG"])
        #expect(try names(PhotoFilter(text: "LILLE")) == ["a.DNG"])
        #expect(try names(PhotoFilter(text: "b.dng")) == ["b.DNG"])
        // Wildcards typed by the user are plain characters.
        #expect(try names(PhotoFilter(text: "%")).isEmpty)
        // A title is given so that the photo can be found by it.
        try catalog.setCredits(PhotoCredits(title: "Rue de la Gare", caption: "The last train."), for: [c])
        #expect(try names(PhotoFilter(text: "rue de la")) == ["c.DNG"])
        #expect(try names(PhotoFilter(text: "last train")) == ["c.DNG"])
    }

    @Test func filtersByDateAndExposure() throws {
        let from = ISO8601DateFormatter.catalog.date(from: "2026-09-16T00:00:00")
        #expect(try names(PhotoFilter(capturedFrom: from)) == ["b.DNG", "c.DNG"])
        #expect(try names(PhotoFilter(capturedTo: from)) == ["a.DNG"])
        #expect(try names(PhotoFilter(minimumISO: 400, maximumISO: 1600)) == ["b.DNG"])
        #expect(try names(PhotoFilter(cameras: ["RICOH GR III"])) == ["a.DNG", "b.DNG"])
    }

    @Test func filtersByEditedState() throws {
        #expect(try names(PhotoFilter(isEdited: true)) == ["a.DNG"])
        #expect(try names(PhotoFilter(isEdited: false)) == ["b.DNG", "c.DNG"])
    }

    @Test func criteriaCombine() throws {
        #expect(try names(PhotoFilter(minimumRating: 3, keywords: ["street"], minimumISO: 200)) == ["b.DNG"])
    }

    @Test func limitsToAnAlbum() throws {
        let album = try catalog.createAlbum(named: "Trip")
        try catalog.add([b, c], toAlbum: album)
        #expect(try names(PhotoFilter(album: album)) == ["b.DNG", "c.DNG"])
        #expect(try names(PhotoFilter(minimumRating: 1, album: album)) == ["b.DNG"])
    }

    @Test func sorts() throws {
        #expect(try names(PhotoFilter(), sort: .captureDate(ascending: false)) == ["c.DNG", "b.DNG", "a.DNG"])
        #expect(try names(PhotoFilter(), sort: .rating) == ["a.DNG", "b.DNG", "c.DNG"])
        #expect(try names(PhotoFilter(), sort: .fileName) == ["a.DNG", "b.DNG", "c.DNG"])
    }

    @Test func listsTheCamerasOfTheLibrary() throws {
        #expect(try catalog.cameras() == ["FUJIFILM X100V", "RICOH GR III"])
    }

    /// At twenty thousand photos, albums and keywords no longer say where anything is: the
    /// sidebar needs the shape of the library in time, read in one pass.
    @Test func theLibraryIsCountedByMonth() throws {
        let months = try catalog.captureMonths()
        let september = try #require(months.first)
        #expect(september.year == 2026 && september.month == 9 && september.count == 3)
        #expect(months.count == 1, "all three were shot in the same month")

        // A photo without a capture date belongs to no month, and is not counted into one.
        _ = try catalog.add(makePhoto("undated.DNG", captured: "not a date", iso: 100))
        #expect(try catalog.captureMonths().map(\.count).reduce(0, +) == 3)
    }
}

/// A smart album is a saved filter, and the filter bar narrows it: a photo shows only if it
/// matches both. Composed in SQL, so that it is true of every criterion by construction.
@Suite struct CombinedFilterTests {
    let catalog: PhotoCatalog

    init() throws {
        catalog = try PhotoCatalog.inMemory()
        for (name, keywords) in [("lille-day.DNG", ["Lille"]), ("lille-night.DNG", ["Lille", "nuit"]), ("paris-night.DNG", ["Paris", "nuit"])] {
            try catalog.setKeywords(keywords, for: try catalog.add(makePhoto(name)))
        }
    }

    private func names(_ filters: [PhotoFilter]) throws -> [String] {
        try catalog.photos(matching: filters, sort: .fileName).map(\.fileName)
    }

    /// Regression: the search of the bar replaced the search the album was saved with, and
    /// the album "Lille" showed every night, in Lille or not.
    @Test func searchingInsideASavedSearchNarrowsIt() throws {
        let lille = PhotoFilter(text: "Lille")
        #expect(try names([lille]) == ["lille-day.DNG", "lille-night.DNG"])
        #expect(try names([lille, PhotoFilter(text: "nuit")]) == ["lille-night.DNG"])
        #expect(try catalog.count(matching: [lille, PhotoFilter(text: "nuit")]) == 1)
    }

    @Test func everyCriterionOfBothFiltersApplies() throws {
        let ids = try catalog.photos(matching: PhotoFilter(), sort: .fileName).map(\.id)
        var fuji = makePhoto("fuji.DNG")
        fuji.camera = "FUJIFILM X100V"
        let other = try catalog.add(fuji)
        let (first, second) = (try catalog.createAlbum(named: "One"), try catalog.createAlbum(named: "Two"))
        try catalog.add([ids[0], ids[1], other], toAlbum: first)
        try catalog.add([ids[1], ids[2], other], toAlbum: second)
        var edits = Adjustments()
        edits.contrast = 5
        try catalog.setAdjustments(edits, for: ids[1])

        #expect(try names([PhotoFilter(album: first), PhotoFilter(album: second)]) == ["fuji.DNG", "lille-night.DNG"])
        #expect(try names([PhotoFilter(cameras: ["RICOH GR III", "FUJIFILM X100V"]), PhotoFilter(cameras: ["FUJIFILM X100V"])]) == ["fuji.DNG"])
        #expect(try names([PhotoFilter(isEdited: true), PhotoFilter(isEdited: false)]).isEmpty)
        #expect(try names([PhotoFilter(isEdited: true, album: first), PhotoFilter(text: "nuit")]) == ["lille-night.DNG"])
    }

    @Test func emptyFiltersChangeNothing() throws {
        #expect(try names([]).count == 3)
        #expect(try names([PhotoFilter(), PhotoFilter(text: "Paris"), PhotoFilter()]) == ["paris-night.DNG"])
    }
}

@Suite struct SmartAlbumTests {
    @Test func aSmartAlbumIsASavedFilterThatStaysUpToDate() throws {
        let catalog = try PhotoCatalog.inMemory()
        let first = try catalog.add(makePhoto("a.DNG"))
        let second = try catalog.add(makePhoto("b.DNG"))
        try catalog.setRating(5, for: [first])

        let id = try catalog.createSmartAlbum(named: "Best", filter: PhotoFilter(minimumRating: 5))
        let album = try #require(try catalog.smartAlbums().first)
        #expect(album.id == id && album.name == "Best" && album.filter == PhotoFilter(minimumRating: 5))
        #expect(try catalog.photos(matching: album.filter).map(\.id) == [first])

        try catalog.setRating(5, for: [second])
        #expect(try catalog.count(matching: album.filter) == 2)
        // Smart albums are not plain albums, and the other way round.
        #expect(try catalog.albums().isEmpty)
    }

    @Test func aSmartAlbumCanBeEditedAndDeleted() throws {
        let catalog = try PhotoCatalog.inMemory()
        let id = try catalog.createSmartAlbum(named: "Best", filter: PhotoFilter(minimumRating: 5))
        try catalog.updateSmartAlbum(id, filter: PhotoFilter(minimumRating: 4, isEdited: true))
        #expect(try catalog.smartAlbums().first?.filter == PhotoFilter(minimumRating: 4, isEdited: true))
        try catalog.deleteAlbum(id)
        #expect(try catalog.smartAlbums().isEmpty)
    }
}
