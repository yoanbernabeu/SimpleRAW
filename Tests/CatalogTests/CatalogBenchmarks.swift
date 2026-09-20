import Foundation
import RawEngine
import Testing
@testable import Catalog

/// What the grid costs on a large library. Timing only means something in release, on a
/// quiet machine: run with
/// `SIMPLERAW_BENCH=1 swift test -c release --filter CatalogBenchmarks`, never as part of `make test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SIMPLERAW_BENCH"] != nil, "Set SIMPLERAW_BENCH"), .serialized)
struct CatalogBenchmarks {
    static let photoCount = 50_000
    /// One photo in five is edited, which is generous for a library of that size.
    static let editedEvery = 5

    /// A catalog on disk, filled in SQL: going through `add` would take longer than what is measured.
    static func makeCatalog(at url: URL) throws -> PhotoCatalog {
        let catalog = try PhotoCatalog(url: url)
        var edits = Adjustments()
        edits.exposure = 0.35
        edits.contrast = 12
        edits.hsl[.blue].saturation = -30
        let json = String(decoding: try edits.jsonData(), as: UTF8.self)
        try catalog.database.execute(
            """
            WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(photoCount))
            INSERT INTO photos (relative_path, file_name, content_hash, imported_at, captured_at, camera, lens, iso,
                                exposure_time, aperture, focal_length, width, height, rating, adjustments, adjustments_fingerprint, is_edited)
            SELECT 'Originals/2026/2026-09-11/R' || i || '.DNG', 'R' || i || '.DNG', 'hash-' || i, 1.0e9 + i, 1.0e9 + i,
                   'RICOH GR III', 'GR LENS 18.3mm', 100 + i % 3200, 0.002, 7.1, 18.3, 6000, 4000, i % 6,
                   CASE WHEN i % \(editedEvery) = 0 THEN ? END, CASE WHEN i % \(editedEvery) = 0 THEN ? END, i % \(editedEvery) = 0
            FROM n
            """,
            [.text(json), .text(AdjustmentsFingerprint.of(json: Data(json.utf8)))]
        )
        return catalog
    }

    static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start) * 1000
    }

    static func median(of runs: Int = 5, _ body: () throws -> Void) rethrows -> Double {
        let times = try (0..<runs).map { _ in try milliseconds(body) }.sorted()
        return times[times.count / 2]
    }

    static func report(_ name: String, _ milliseconds: Double) {
        print(String(format: "BENCH %-52@ %8.1f ms", name as NSString, milliseconds))
    }

    @Test func readingTheWholeLibraryForTheGrid() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-bench-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let catalog = try Self.makeCatalog(at: file)

        var photos: [Photo] = []
        Self.report("photos(matching:) on \(Self.photoCount) photos", try Self.median { photos = try catalog.photos(matching: PhotoFilter()) })
        #expect(photos.count == Self.photoCount)

        for (name, sort) in [("import date", PhotoSort.importDate), ("rating", .rating), ("file name", .fileName)] {
            Self.report("photos(matching:) sorted by \(name)", try Self.median { _ = try catalog.photos(matching: PhotoFilter(), sort: sort) })
        }

        // What a screenful of edited cells pays: its edits decoded, once, then its thumbnails found.
        let cells = Array(photos.lazy.filter { $0.id % Int64(Self.editedEvery) == 0 }.prefix(300))
        Self.report("decoding the edits of \(cells.count) cells, first time", Self.milliseconds { for photo in cells { _ = photo.isEdited } })
        let store = ThumbnailStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-bench-none"))
        Self.report("cachedURL(for:) for \(cells.count) edited cells", Self.median { for photo in cells { _ = store.cachedURL(for: photo) } })
    }

    /// Removing photos cascades to albums and keywords: a scan of both tables per photo
    /// without `album_photos_photo` and `photo_keywords_keyword` (376 ms for 200 photos, 3 ms with).
    @Test func removingPhotosThatAreInAlbumsAndHaveKeywords() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-bench-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let catalog = try Self.makeCatalog(at: file)
        let ids = try catalog.photos(matching: PhotoFilter()).map(\.id)
        try catalog.add(ids, toAlbum: try catalog.createAlbum(named: "All"))
        Self.report("addKeywords, two of them, to \(ids.count) photos", try Self.milliseconds { try catalog.addKeywords(["one", "two"], to: ids) })
        Self.report("commonKeywords(of:) \(ids.count) photos", try Self.median { _ = try catalog.commonKeywords(of: ids) })
        try catalog.remove(Array(ids[0..<200]))
        Self.report("remove 200 photos", try Self.milliseconds { try catalog.remove(Array(ids[200..<400])) })
        Self.report("setRating on \(ids.count - 400) photos", try Self.milliseconds { try catalog.setRating(2, for: Array(ids[400...])) })
    }

    /// The small statements the interface makes all day: what keeping them compiled saves.
    @Test func smallHotStatements() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-bench-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let catalog = try Self.makeCatalog(at: file)
        Self.report("photo(id), 10 000 times", try Self.median { for id in 1...10_000 { _ = try catalog.photo(Int64(id)) } })
        Self.report("keywords(for:), 10 000 times", try Self.median { for id in 1...10_000 { _ = try catalog.keywords(for: Int64(id)) } })
    }
}
