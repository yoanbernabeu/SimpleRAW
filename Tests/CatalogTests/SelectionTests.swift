import Foundation
import RawEngine
import Testing
@testable import Catalog

/// What the grid does to a whole selection: one call, one transaction, whatever its size.
@Suite struct SelectionKeywordTests {
    let catalog: PhotoCatalog
    /// a: street, Lille — b: street — c: nothing
    let a: Int64, b: Int64, c: Int64

    init() throws {
        catalog = try PhotoCatalog.inMemory()
        a = try catalog.add(makePhoto("a.DNG"))
        b = try catalog.add(makePhoto("b.DNG"))
        c = try catalog.add(makePhoto("c.DNG"))
        try catalog.setKeywords(["street", "Lille"], for: a)
        try catalog.setKeywords(["street"], for: b)
    }

    @Test func theKeywordsASelectionSharesAreThoseOfEveryPhoto() throws {
        #expect(try catalog.commonKeywords(of: [a, b]) == ["street"])
        #expect(try catalog.commonKeywords(of: [a]) == ["Lille", "street"])
        #expect(try catalog.commonKeywords(of: [a, b, c]).isEmpty)
        #expect(try catalog.commonKeywords(of: []).isEmpty)
        // A photo listed twice is one photo.
        #expect(try catalog.commonKeywords(of: [a, a, b]) == ["street"])
    }

    /// The point of adding and removing: every photo keeps the keywords that are its own.
    @Test func addingToASelectionKeepsWhatEachPhotoHad() throws {
        try catalog.addKeywords([" night ", "STREET", ""], to: [a, b, c])
        #expect(try catalog.keywords(for: a) == ["Lille", "night", "street"])
        #expect(try catalog.keywords(for: b) == ["night", "street"])
        // "STREET" is the keyword that already exists, not a new one.
        #expect(try catalog.keywords(for: c) == ["night", "street"])
    }

    @Test func removingFromASelectionLeavesTheOtherKeywordsAndForgetsUnusedOnes() throws {
        try catalog.removeKeywords(["Street", "nope"], from: [a, b, c])
        #expect(try catalog.keywords(for: a) == ["Lille"])
        #expect(try catalog.keywords(for: b).isEmpty)
        #expect(try catalog.allKeywords().map(\.name) == ["Lille"])
    }

    @Test func settingReplacesTheKeywordsOfEveryPhotoOfTheSelection() throws {
        try catalog.setKeywords(["trip"], for: [a, c])
        #expect(try catalog.keywords(for: a) == ["trip"] && catalog.keywords(for: c) == ["trip"])
        #expect(try catalog.keywords(for: b) == ["street"])
        #expect(try catalog.allKeywords().map(\.name) == ["street", "trip"])
    }

    /// Regression: the same keyword in two spellings broke the key of `photo_keywords`.
    @Test func theSameKeywordInTwoSpellingsIsOneKeyword() throws {
        try catalog.setKeywords(["Night", "night"], for: c)
        #expect(try catalog.keywords(for: c).count == 1)
    }

    @Test func aChangeToASelectionIsAllOrNothing() throws {
        try catalog.database.execute(
            "CREATE TRIGGER refuse_c BEFORE INSERT ON photo_keywords WHEN new.photo_id = \(c) BEGIN SELECT RAISE(ABORT, 'refused'); END"
        )
        #expect(throws: DatabaseError.self) { try catalog.addKeywords(["night"], to: [a, b, c]) }
        #expect(try catalog.keywords(for: a) == ["Lille", "street"])
        #expect(try catalog.allKeywords().map(\.name) == ["Lille", "street"])
    }
}

@Suite struct SelectionAdjustmentsTests {
    @Test func theEditsOfASelectionAreSavedTogetherOrNotAtAll() throws {
        let catalog = try PhotoCatalog.inMemory()
        let ids = try ["a.DNG", "b.DNG"].map { try catalog.add(makePhoto($0)) }
        var soft = Adjustments()
        soft.contrast = -10
        var hard = Adjustments()
        hard.contrast = 40
        try catalog.setAdjustments([ids[0]: soft, ids[1]: hard])
        #expect(try ids.map { try catalog.photo($0)?.adjustments.contrast } == [-10, 40])

        var broken = Adjustments()
        broken.exposure = .nan
        #expect(throws: (any Error).self) { try catalog.setAdjustments([ids[0]: Adjustments(), ids[1]: broken]) }
        #expect(try catalog.photo(ids[0])?.adjustments == soft)
    }
}

/// "Select all" on a large library: more ids than SQLite takes parameters in one statement.
@Suite struct LargeSelectionTests {
    static let count = 50_000
    let catalog: PhotoCatalog
    let ids: [Int64]

    init() throws {
        catalog = try PhotoCatalog.inMemory()
        try catalog.database.execute(
            """
            WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(Self.count))
            INSERT INTO photos (relative_path, file_name, content_hash, imported_at, width, height)
            SELECT 'Originals/' || i || '.DNG', i || '.DNG', 'hash-' || i, i, 6000, 4000 FROM n
            """
        )
        ids = try catalog.photos(matching: PhotoFilter()).map(\.id)
    }

    @Test func everyOperationOnIdsHoldsAtFiftyThousand() throws {
        #expect(ids.count == Self.count)
        try catalog.setRating(3, for: ids)
        try catalog.setFlag(.picked, for: ids)
        try catalog.setColorLabel(.green, for: ids)
        #expect(try catalog.count(matching: PhotoFilter(minimumRating: 3, flags: [.picked], colorLabels: [.green])) == Self.count)

        try catalog.addKeywords(["all", "of them"], to: ids)
        #expect(try catalog.commonKeywords(of: ids) == ["all", "of them"])
        try catalog.removeKeywords(["all"], from: Array(ids.dropLast()))
        #expect(try catalog.commonKeywords(of: ids) == ["of them"])
        #expect(try catalog.allKeywords() == [KeywordCount(name: "all", count: 1), KeywordCount(name: "of them", count: Self.count)])

        let album = try catalog.createAlbum(named: "Everything")
        try catalog.add(ids, toAlbum: album)
        #expect(try catalog.photoCount(inAlbum: album) == Self.count)
        try catalog.remove(Array(ids.dropFirst()), fromAlbum: album)
        #expect(try catalog.photoCount(inAlbum: album) == 1)

        try catalog.remove(ids)
        #expect(try catalog.count(matching: PhotoFilter()) == 0)
        #expect(try catalog.allKeywords().isEmpty)
    }
}
