import Foundation
import Testing
@testable import Catalog

/// Indexes are only worth their cost if SQLite picks them: asked here, not assumed.
@Suite struct IndexTests {
    let catalog: PhotoCatalog

    init() throws {
        catalog = try PhotoCatalog.inMemory()
    }

    private func plan(_ sql: String, _ bindings: [DatabaseValue] = []) throws -> String {
        try catalog.database.query("EXPLAIN QUERY PLAN \(sql)", bindings) { try $0.string("detail") }.joined(separator: "\n")
    }

    private func plan(_ filter: PhotoFilter = PhotoFilter(), sort: PhotoSort) throws -> String {
        let (sql, bindings) = PhotoCatalog.select("*", matching: [filter], sort: sort)
        return try plan(sql, bindings)
    }

    /// Sorting 50 000 rows on every reload is what an index on the sort key avoids.
    @Test(arguments: [PhotoSort.captureDate(ascending: false), .captureDate(ascending: true), .importDate, .rating, .fileName])
    func everySortReadsAnIndexInsteadOfSorting(sort: PhotoSort) throws {
        let plan = try plan(sort: sort)
        #expect(plan.contains("USING INDEX") && !plan.contains("TEMP B-TREE"), "\(plan)")
    }

    /// Removing a photo cascades to these two tables, by photo; forgetting unused keywords
    /// looks `photo_keywords` up by keyword. Without an index each is a scan of the whole table.
    @Test func cascadesAndKeywordCleanupSearchInsteadOfScanning() throws {
        #expect(try plan("SELECT 1 FROM album_photos WHERE photo_id = ?", [1]).contains("album_photos_photo"))
        #expect(try plan("SELECT 1 FROM photo_keywords WHERE photo_id = ?", [1]).contains("SEARCH"))
        #expect(try plan("SELECT 1 FROM photo_keywords WHERE keyword_id = ?", [1]).contains("photo_keywords_keyword"))
        let cleanup = try plan("DELETE FROM keywords WHERE id NOT IN (SELECT keyword_id FROM photo_keywords)")
        #expect(cleanup.contains("photo_keywords_keyword"), "\(cleanup)")
    }

    /// Few photos are picked, labelled or edited: those filters read a small partial index.
    @Test func rareStatesAreFoundThroughPartialIndexes() throws {
        let counting = { (filter: PhotoFilter) -> String in
            let (sql, bindings) = PhotoCatalog.select("COUNT(*)", matching: [filter], sort: nil)
            return try plan(sql, bindings)
        }
        #expect(try counting(PhotoFilter(flags: [.picked, .rejected])).contains("photos_flag"))
        #expect(try counting(PhotoFilter(colorLabels: [.red])).contains("photos_color_label"))
        #expect(try counting(PhotoFilter(isEdited: true)).contains("photos_is_edited"))
        // Unflagged and unedited photos are most of the library: no partial index, and no wrong result.
        #expect(try !counting(PhotoFilter(flags: [.none, .picked])).contains("photos_flag"))
        #expect(try !counting(PhotoFilter(isEdited: false)).contains("photos_is_edited"))
    }

    @Test func aCatalogFromBeforeTheIndexesGetsThemAndKeepsItsPhotos() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-catalog-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        do {
            let old = try Database(url: file)
            try old.migrate(Array(PhotoCatalog.migrations.prefix(3)))
            try old.execute("INSERT INTO photos (relative_path, file_name, content_hash, imported_at, width, height, flag) VALUES ('Originals/a.DNG', 'a.DNG', 'h', 0, 1, 1, 1)")
        }
        let migrated = try PhotoCatalog(url: file)
        #expect(try migrated.photos(matching: PhotoFilter(flags: [.picked])).map(\.fileName) == ["a.DNG"])
        let indexes = try migrated.database.query("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'") { try $0.string("name") }
        #expect(Set(indexes) == [
            "photos_captured_at", "photos_imported_at", "photos_file_name", "photos_rating_captured_at", "photos_flag",
            "photos_color_label", "photos_is_edited", "album_photos_photo", "photo_keywords_keyword",
            "photo_versions_photo",
        ])
    }
}
