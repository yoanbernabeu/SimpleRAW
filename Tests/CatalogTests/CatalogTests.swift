import Foundation
import RawEngine
import Testing
@testable import Catalog

extension ISO8601DateFormatter {
    /// Capture times as cameras write them: local time, no zone. They are kept as if UTC,
    /// which is consistent and sorts correctly.
    nonisolated(unsafe) static let catalog: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// A photo record with sensible values, to be tweaked per test.
func makePhoto(_ name: String = "R0001.DNG", captured: String = "2026-09-11T11:14:40", iso: Int = 100, hash: String? = nil) -> NewPhoto {
    NewPhoto(
        relativePath: "Originals/2026/2026-09-11/\(name)",
        fileName: name,
        contentHash: hash ?? "hash-\(name)",
        captureDate: ISO8601DateFormatter.catalog.date(from: captured),
        camera: "RICOH GR III",
        lens: nil,
        iso: iso,
        exposureTime: 1.0 / 500,
        aperture: 7.1,
        focalLength: 18.3,
        width: 6000,
        height: 4000
    )
}

@Suite struct CatalogPhotoTests {
    let catalog: PhotoCatalog

    init() throws {
        catalog = try PhotoCatalog.inMemory()
    }

    @Test func anAddedPhotoComesBackWithItsMetadata() throws {
        let id = try catalog.add(makePhoto())
        let photo = try #require(try catalog.photo(id))
        #expect(photo.fileName == "R0001.DNG" && photo.iso == 100 && photo.camera == "RICOH GR III")
        #expect(photo.width == 6000 && photo.aperture == 7.1)
        #expect(photo.rating == 0 && photo.flag == .none && photo.colorLabel == nil)
        #expect(photo.adjustments == Adjustments())
    }

    @Test func theSameFileIsNotAddedTwice() throws {
        let first = try catalog.add(makePhoto(hash: "same"))
        #expect(try catalog.photoID(withContentHash: "same") == first)
        #expect(try catalog.photoID(withContentHash: "other") == nil)
        #expect(throws: DatabaseError.self) { try catalog.add(makePhoto("copy.DNG", hash: "same")) }
    }

    @Test func ratingsFlagsAndLabelsAreSaved() throws {
        let id = try catalog.add(makePhoto())
        try catalog.setRating(4, for: [id])
        try catalog.setFlag(.picked, for: [id])
        try catalog.setColorLabel(.red, for: [id])
        let photo = try #require(try catalog.photo(id))
        #expect(photo.rating == 4 && photo.flag == .picked && photo.colorLabel == .red)
        try catalog.setColorLabel(nil, for: [id])
        #expect(try catalog.photo(id)?.colorLabel == nil)
    }

    @Test func aRatingStaysBetweenZeroAndFive() throws {
        let id = try catalog.add(makePhoto())
        try catalog.setRating(9, for: [id])
        #expect(try catalog.photo(id)?.rating == 5)
        try catalog.setRating(-2, for: [id])
        #expect(try catalog.photo(id)?.rating == 0)
    }

    @Test func aChangeAppliesToEveryPhotoOfTheSelection() throws {
        let ids = try ["a.DNG", "b.DNG", "c.DNG"].map { try catalog.add(makePhoto($0)) }
        try catalog.setRating(3, for: Array(ids.prefix(2)))
        #expect(try ids.map { try catalog.photo($0)?.rating } == [3, 3, 0])
    }

    @Test func adjustmentsLiveInTheCatalog() throws {
        let id = try catalog.add(makePhoto())
        var adjustments = Adjustments()
        adjustments.contrast = 25
        adjustments.hsl[.blue].saturation = -30
        try catalog.setAdjustments(adjustments, for: id)
        #expect(try catalog.photo(id)?.adjustments == adjustments)
        #expect(try catalog.photo(id)?.isEdited == true)
    }

    @Test func removingAPhotoRemovesWhatHangsOffIt() throws {
        let id = try catalog.add(makePhoto())
        try catalog.setKeywords(["street"], for: id)
        let album = try catalog.createAlbum(named: "Trip")
        try catalog.add([id], toAlbum: album)
        try catalog.remove([id])
        #expect(try catalog.photo(id) == nil)
        #expect(try catalog.photoCount(inAlbum: album) == 0)
    }
}

@Suite struct CatalogKeywordTests {
    let catalog: PhotoCatalog

    init() throws {
        catalog = try PhotoCatalog.inMemory()
    }

    @Test func keywordsAreTrimmedDeduplicatedAndSorted() throws {
        let id = try catalog.add(makePhoto())
        try catalog.setKeywords([" street ", "Lille", "street", ""], for: id)
        #expect(try catalog.keywords(for: id) == ["Lille", "street"])
    }

    @Test func settingKeywordsReplacesThePreviousOnes() throws {
        let id = try catalog.add(makePhoto())
        try catalog.setKeywords(["a", "b"], for: id)
        try catalog.setKeywords(["b", "c"], for: id)
        #expect(try catalog.keywords(for: id) == ["b", "c"])
    }

    @Test func theKeywordListCountsPhotosAndForgetsUnusedKeywords() throws {
        let first = try catalog.add(makePhoto("a.DNG"))
        let second = try catalog.add(makePhoto("b.DNG"))
        try catalog.setKeywords(["street", "night"], for: first)
        try catalog.setKeywords(["street"], for: second)
        #expect(try catalog.allKeywords().map { "\($0.name):\($0.count)" } == ["night:1", "street:2"])
        try catalog.setKeywords([], for: first)
        #expect(try catalog.allKeywords().map(\.name) == ["street"])
    }
}

/// The title, the caption, the author and the copyright of a photo: what the catalog knows
/// about the picture that the camera never wrote, and the export puts into the file.
@Suite struct CatalogCreditsTests {
    let catalog: PhotoCatalog

    init() throws {
        catalog = try PhotoCatalog.inMemory()
    }

    @Test func aPhotoRemembersWhatIsSaidAboutIt() throws {
        let id = try catalog.add(makePhoto())
        #expect(try catalog.credits(for: id) == PhotoCredits())
        try catalog.setCredits(
            PhotoCredits(title: "Rue de la Gare", caption: "The last train.", author: "Yoan", copyright: "© 2026 Yoan"),
            for: [id]
        )
        let credits = try catalog.credits(for: id)
        #expect(credits.title == "Rue de la Gare" && credits.caption == "The last train.")
        #expect(credits.author == "Yoan" && credits.copyright == "© 2026 Yoan")
        // Read off the row too: the grid must not need a query per photo to show a title.
        #expect(try catalog.photo(id)?.credits.title == "Rue de la Gare")
    }

    /// Read back with the keywords: one value, the one the export writes.
    @Test func theKeywordsComeWithThem() throws {
        let id = try catalog.add(makePhoto())
        try catalog.setKeywords(["street", "Lille"], for: id)
        try catalog.setCredits(PhotoCredits(title: "Gare"), for: [id])
        #expect(try catalog.credits(for: id) == PhotoCredits(title: "Gare", keywords: ["Lille", "street"]))
    }

    /// Blank is nothing: what is cleared leaves the catalog rather than becoming an empty line.
    @Test func blankFieldsAreStoredAsNothing() throws {
        let id = try catalog.add(makePhoto())
        try catalog.setCredits(PhotoCredits(title: "Gare", author: "Yoan"), for: [id])
        try catalog.setCredits(PhotoCredits(title: "  ", author: "Yoan"), for: [id])
        #expect(try catalog.credits(for: id) == PhotoCredits(author: "Yoan"))
        #expect(try catalog.photo(id)?.credits.title == nil)
    }

    /// An author and a copyright are set on a whole shoot at once; a title never is, so it is
    /// left alone by a change that does not carry one.
    @Test func anAuthorIsSetOnAWholeSelectionWithoutTouchingEachTitle() throws {
        let ids = try ["a.DNG", "b.DNG"].map { try catalog.add(makePhoto($0)) }
        try catalog.setCredits(PhotoCredits(title: "Gare"), for: [ids[0]])
        try catalog.setSignature(author: "Yoan", copyright: "© 2026 Yoan", for: ids)
        #expect(try ids.map { try catalog.credits(for: $0).author } == ["Yoan", "Yoan"])
        #expect(try catalog.credits(for: ids[0]).title == "Gare")
        #expect(try catalog.credits(for: ids[1]).title == nil)
    }

    /// A library written before the columns existed opens, and a photo of it can be given a
    /// title like any other.
    @Test func anOlderCatalogGetsTheColumns() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-credits-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        do {
            let old = try Database(url: file)
            // The six steps this library was written with, before the credits column existed.
            try old.migrate(Array(PhotoCatalog.migrations.prefix(6)))
            try old.execute("INSERT INTO photos (relative_path, file_name, content_hash, imported_at, width, height) VALUES ('Originals/a.DNG', 'a.DNG', 'h', 0, 1, 1)")
        }
        let migrated = try PhotoCatalog(url: file)
        let id = try #require(try migrated.photos(matching: PhotoFilter()).first).id
        #expect(try migrated.credits(for: id) == PhotoCredits())
        try migrated.setCredits(PhotoCredits(title: "Gare"), for: [id])
        #expect(try migrated.credits(for: id).title == "Gare")
    }
}

@Suite struct CatalogAlbumTests {
    let catalog: PhotoCatalog

    init() throws {
        catalog = try PhotoCatalog.inMemory()
    }

    @Test func albumsHoldPhotosWithoutOwningThem() throws {
        let ids = try ["a.DNG", "b.DNG"].map { try catalog.add(makePhoto($0)) }
        let album = try catalog.createAlbum(named: "Trip")
        try catalog.add(ids, toAlbum: album)
        try catalog.add(ids, toAlbum: album)  // adding twice is harmless
        #expect(try catalog.photoCount(inAlbum: album) == 2)

        try catalog.remove([ids[0]], fromAlbum: album)
        #expect(try catalog.photoCount(inAlbum: album) == 1)
        #expect(try catalog.photo(ids[0]) != nil)
    }

    @Test func albumsAreListedByNameAndCanBeRenamedAndDeleted() throws {
        let trip = try catalog.createAlbum(named: "Trip")
        _ = try catalog.createAlbum(named: "Family")
        try catalog.renameAlbum(trip, to: "Berlin")
        #expect(try catalog.albums().map(\.name) == ["Berlin", "Family"])
        try catalog.deleteAlbum(trip)
        #expect(try catalog.albums().map(\.name) == ["Family"])
    }
}

@Suite struct CatalogPersistenceTests {
    @Test func aCatalogOnDiskSurvivesBeingReopened() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-catalog-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let id: Int64
        do {
            let catalog = try PhotoCatalog(url: file)
            id = try catalog.add(makePhoto())
            try catalog.setRating(5, for: [id])
        }
        #expect(try PhotoCatalog(url: file).photo(id)?.rating == 5)
    }
}

@Suite struct UnreadableCatalogEditsTests {
    let catalog: PhotoCatalog
    let good: Int64
    let damaged: Int64

    init() throws {
        catalog = try PhotoCatalog.inMemory()
        good = try catalog.add(makePhoto("good.DNG"))
        damaged = try catalog.add(makePhoto("damaged.DNG"))
        try catalog.database.execute("UPDATE photos SET adjustments = ?, is_edited = 1 WHERE id = ?", ["{not json", .int(damaged)])
    }

    /// Regression: one row whose JSON could not be decoded made every query throw, which
    /// emptied the whole grid.
    @Test func oneUnreadableRowDoesNotHideTheOthers() throws {
        let photos = try catalog.photos(matching: PhotoFilter(), sort: .fileName)
        #expect(photos.map(\.fileName) == ["damaged.DNG", "good.DNG"])
        #expect(photos[0].adjustments == Adjustments() && photos[0].hasUnreadableAdjustments)
        #expect(!photos[1].hasUnreadableAdjustments)
    }

    @Test func savingOverUnreadableEditsKeepsThem() throws {
        var edits = Adjustments()
        edits.contrast = 10
        try catalog.setAdjustments(edits, for: damaged)
        #expect(try catalog.photo(damaged)?.adjustments == edits)
        #expect(try catalog.unreadableAdjustments(for: damaged) == "{not json")
        // Readable edits are simply replaced: nothing piles up.
        try catalog.setAdjustments(edits, for: good)
        try catalog.setAdjustments(Adjustments(), for: good)
        #expect(try catalog.unreadableAdjustments(for: good) == nil)
    }
}

/// A thumbnail is named after the edits it shows. The name comes with the row: drawing a
/// cell of the grid must not encode or hash anything.
@Suite struct AdjustmentsFingerprintTests {
    let catalog: PhotoCatalog
    let id: Int64
    var edits = Adjustments()

    init() throws {
        catalog = try PhotoCatalog.inMemory()
        id = try catalog.add(makePhoto())
        edits.contrast = 25
    }

    private func storedFingerprint() throws -> String? {
        try catalog.database.query("SELECT adjustments_fingerprint FROM photos WHERE id = ?", [.int(id)]) { try $0.optionalString("adjustments_fingerprint") }.first ?? nil
    }

    @Test func theFingerprintIsSavedWithTheEdits() throws {
        #expect(try catalog.photo(id)?.adjustmentsFingerprint == "neutral")
        try catalog.setAdjustments(edits, for: id)
        let saved = try #require(try storedFingerprint())
        #expect(try catalog.photo(id)?.adjustmentsFingerprint == saved)

        var others = edits
        others.contrast = 26
        try catalog.setAdjustments(others, for: id)
        #expect(try storedFingerprint() != saved)
        try catalog.setAdjustments(Adjustments(), for: id)
        #expect(try storedFingerprint() == nil)
        #expect(try catalog.photo(id)?.adjustmentsFingerprint == "neutral")
    }

    /// A photo edited in memory, not read back yet, names the same thumbnail as the saved one.
    @Test func equalEditsShareAFingerprintWhereverTheyComeFrom() throws {
        try catalog.setAdjustments(edits, for: id)
        let inMemory = Photo(id: 9, file: makePhoto(), importDate: Date(), rating: 0, flag: .none, colorLabel: nil, adjustments: edits, isEdited: true)
        #expect(try inMemory.adjustmentsFingerprint == catalog.photo(id)?.adjustmentsFingerprint)

        var changed = try #require(try catalog.photo(id))
        changed.adjustments.contrast = 40
        #expect(try changed.adjustmentsFingerprint != catalog.photo(id)?.adjustmentsFingerprint)
    }

    /// Regression: edits that could not be encoded were given the neutral thumbnail.
    @Test func editsThatCannotBeEncodedHaveNoFingerprint() {
        var broken = Adjustments()
        broken.exposure = .nan
        let photo = Photo(id: 1, file: makePhoto(), importDate: Date(), rating: 0, flag: .none, colorLabel: nil, adjustments: broken, isEdited: true)
        #expect(throws: (any Error).self) { try photo.adjustmentsFingerprint }
    }

    @Test func photosCompareByWhatTheyHold() throws {
        try catalog.setAdjustments(edits, for: id)
        let first = try #require(try catalog.photo(id))
        #expect(try catalog.photo(id) == first)
        var inMemory = first
        inMemory.adjustments = edits
        #expect(inMemory == first)
        inMemory.adjustments.contrast = 1
        #expect(inMemory != first)
    }

    /// A library written before the column existed: opening it adds the column, and the
    /// edits it already holds name their thumbnails as if they had just been saved.
    @Test func anOlderCatalogGetsTheColumnAndKeepsItsEdits() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-catalog-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        do {
            let old = try Database(url: file)
            try old.migrate(Array(PhotoCatalog.migrations.prefix(2)))
            try old.execute(
                """
                INSERT INTO photos (relative_path, file_name, content_hash, imported_at, width, height, adjustments, is_edited)
                VALUES ('Originals/a.DNG', 'a.DNG', 'h', 0, 1, 1, ?, 1)
                """,
                [.text(String(decoding: try edits.jsonData(), as: UTF8.self))]
            )
        }
        let migrated = try PhotoCatalog(url: file)
        let photo = try #require(try migrated.photos(matching: PhotoFilter()).first)
        #expect(photo.adjustments == edits && photo.isEdited)

        let fresh = try migrated.add(makePhoto("b.DNG"))
        try migrated.setAdjustments(edits, for: fresh)
        #expect(try photo.adjustmentsFingerprint == migrated.photo(fresh)?.adjustmentsFingerprint)
    }
}
