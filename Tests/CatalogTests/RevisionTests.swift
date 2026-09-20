import Foundation
import RawEngine
import Testing
@testable import Catalog

/// How a backup knows, for the price of reading one integer, whether the catalog has
/// anything new to send.
@Suite struct RevisionTests {
    let catalog: PhotoCatalog

    init() throws {
        catalog = try PhotoCatalog.inMemory()
    }

    private func bumps(_ change: () throws -> Void) throws -> Bool {
        let before = try catalog.revision
        try change()
        return try catalog.revision > before
    }

    @Test func everyKindOfChangeMovesTheRevision() throws {
        var id: Int64 = 0
        #expect(try bumps { id = try catalog.add(makePhoto()) })
        #expect(try bumps { try catalog.setRating(3, for: [id]) })
        #expect(try bumps { try catalog.setFlag(.picked, for: [id]) })
        #expect(try bumps { try catalog.setColorLabel(.red, for: [id]) })
        var edits = Adjustments()
        edits.contrast = 10
        #expect(try bumps { try catalog.setAdjustments(edits, for: id) })
        #expect(try bumps { try catalog.setKeywords(["street"], for: id) })
        var album: Int64 = 0
        #expect(try bumps { album = try catalog.createAlbum(named: "Trip") })
        #expect(try bumps { try catalog.add([id], toAlbum: album) })
        #expect(try bumps { try catalog.renameAlbum(album, to: "Berlin") })
        #expect(try bumps { try catalog.remove([id], fromAlbum: album) })
        #expect(try bumps { try catalog.createSmartAlbum(named: "Best", filter: PhotoFilter(minimumRating: 5)) })
        #expect(try bumps { try catalog.deleteAlbum(album) })
        #expect(try bumps { try catalog.remove([id]) })
    }

    @Test func readingChangesNothing() throws {
        let id = try catalog.add(makePhoto())
        #expect(try !bumps {
            _ = try catalog.photos(matching: PhotoFilter(text: "a"))
            _ = try catalog.photo(id)
            _ = try catalog.allKeywords()
            _ = try catalog.contentFingerprint()
        })
    }

    @Test func aChangeThatIsRolledBackDoesNotCount() throws {
        struct Boom: Error {}
        let before = try catalog.revision
        #expect(throws: Boom.self) {
            try catalog.database.transaction {
                try catalog.add(makePhoto())
                throw Boom()
            }
        }
        #expect(try catalog.revision == before)
    }

    /// A counter kept in memory would start over with every launch and miss what changed.
    @Test func theRevisionLivesInTheFileAndInItsSnapshots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("catalog.sqlite")
        let revision: Int64
        do {
            let catalog = try PhotoCatalog(url: file)
            try catalog.add(makePhoto())
            revision = try catalog.revision
        }
        let reopened = try PhotoCatalog(url: file)
        #expect(try reopened.revision == revision && revision > 0)

        // What a backup records is the revision of the very snapshot it uploads.
        let snapshot = folder.appendingPathComponent("snapshot.sqlite")
        try reopened.snapshot(to: snapshot)
        try reopened.setRating(5, for: [1])
        #expect(try PhotoCatalog.revision(ofCatalogAt: snapshot) == revision)
        #expect(try reopened.revision > revision)
    }

    @Test func aCatalogFromBeforeTheCounterGetsOne() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-catalog-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        do {
            let old = try Database(url: file)
            try old.migrate(Array(PhotoCatalog.migrations.prefix(4)))
            try old.execute("INSERT INTO photos (relative_path, file_name, content_hash, imported_at, width, height) VALUES ('Originals/a.DNG', 'a.DNG', 'h', 0, 1, 1)")
        }
        let migrated = try PhotoCatalog(url: file)
        let before = try migrated.revision
        try migrated.setRating(2, for: [1])
        #expect(try migrated.revision > before)
        #expect(try migrated.photos(matching: PhotoFilter()).map(\.rating) == [2])
    }

    /// The triggers behind the counter are part of what the app creates: a restored catalog
    /// that carries them is accepted, and one that carries another is still refused.
    @Test func theCounterIsPartOfTheExpectedSchema() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshot = folder.appendingPathComponent("snapshot.sqlite")
        try catalog.add(makePhoto())
        try catalog.snapshot(to: snapshot)
        #expect(try PhotoCatalog.validateForeignCatalog(at: snapshot).photoCount == 1)
        #expect(try catalog.database.query("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'trigger'") { try $0.int("n") } == [18], "three per watched table")
    }
}

/// The interface shares one connection with whatever runs in the background. A snapshot of
/// a large catalog takes a second: it must not hold that connection's lock meanwhile.
@Suite struct SnapshotConnectionTests {
    @Test func aSnapshotOfACatalogOnDiskLeavesTheMainConnectionFree() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try PhotoCatalog(url: folder.appendingPathComponent("catalog.sqlite"))
        let id = try catalog.add(makePhoto())
        try catalog.setRating(4, for: [id])

        let snapshot = folder.appendingPathComponent("snapshot.sqlite")
        var statementsOnTheMainConnection = 0
        try catalog.database.countingStatements({ statementsOnTheMainConnection += 1 }) {
            try catalog.snapshot(to: snapshot)
        }
        #expect(statementsOnTheMainConnection == 0)
        // Complete, and what was committed last is in it, not only what was checkpointed.
        #expect(try PhotoCatalog(url: snapshot).photo(id)?.rating == 4)
    }

    @Test func aSnapshotReplacesAFileLeftThere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try PhotoCatalog(url: folder.appendingPathComponent("catalog.sqlite"))
        let snapshot = folder.appendingPathComponent("snapshot.sqlite")
        try Data("left over".utf8).write(to: snapshot)
        try catalog.snapshot(to: snapshot)
        #expect(try PhotoCatalog.validateForeignCatalog(at: snapshot).photoCount == 0)
    }
}
