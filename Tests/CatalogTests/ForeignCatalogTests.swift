import Foundation
import Testing
@testable import Catalog

/// A catalog that comes back from a backup store, or from someone else's disk, is a file
/// written by a stranger: it is checked before the app opens it.
@Suite struct ForeignCatalogTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-foreign-\(UUID().uuidString)")
    var file: URL { folder.appendingPathComponent("catalog.sqlite") }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A catalog as a backup uploads it, holding one photo at `path`, then tampered with.
    private func makeCatalog(path: String = "Originals/2026/2026-09-11/R0001.DNG", tamper: String? = nil) throws {
        var photo = makePhoto()
        photo.relativePath = path
        let catalog = try PhotoCatalog.inMemory()
        try catalog.add(photo)
        try catalog.snapshot(to: file)
        if let tamper { try Database(url: file).execute(tamper) }
    }

    @Test func aCatalogWrittenByTheAppIsAccepted() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeCatalog()
        let report = try PhotoCatalog.validateForeignCatalog(at: file)
        #expect(report.photoCount == 1 && report.escapingPaths.isEmpty)
    }

    /// Anything the migrations do not create could run inside the app's own connection.
    @Test(arguments: [
        "CREATE TRIGGER steal AFTER UPDATE ON photos BEGIN DELETE FROM albums; END",
        "CREATE VIEW everything AS SELECT * FROM photos",
        "CREATE TABLE extra (id INTEGER PRIMARY KEY)",
        "CREATE INDEX extra_index ON photos (lens)",
    ])
    func aCatalogWithAnythingTheAppDidNotCreateIsRefused(tamper: String) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeCatalog(tamper: tamper)
        #expect(throws: ForeignCatalogError.self) { try PhotoCatalog.validateForeignCatalog(at: file) }
    }

    @Test func aFileThatIsNotADatabaseIsDamaged() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a database, whatever its name".utf8).write(to: file)
        #expect { try PhotoCatalog.validateForeignCatalog(at: file) } throws: { error in
            if case ForeignCatalogError.damaged = error { true } else { false }
        }
    }

    @Test func aKnownTableWithAnotherDefinitionIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeCatalog(tamper: "ALTER TABLE albums ADD COLUMN surprise TEXT")
        #expect(throws: ForeignCatalogError.self) { try PhotoCatalog.validateForeignCatalog(at: file) }
    }

    @Test(arguments: ["../../../etc/hosts", "/etc/hosts", "Originals/../catalog.sqlite", "Originals/./a.DNG", "Previews/a.jpg", "Originals", "Originals//a.DNG", ""])
    func aPathThatLeavesTheOriginalsIsReported(path: String) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeCatalog(path: path)
        let report = try PhotoCatalog.validateForeignCatalog(at: file)
        #expect(report.escapingPaths == [path])
    }

    @Test func aFileThatIsNotADatabaseIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 0x41, count: 8192).write(to: file)
        #expect(throws: (any Error).self) { try PhotoCatalog.validateForeignCatalog(at: file) }
    }

    /// A backup made by an older version of the app is still a backup.
    @Test func aCatalogFromAnOlderVersionIsAccepted() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try Database(url: file).migrate(Array(PhotoCatalog.migrations.prefix(1)))
        #expect(try PhotoCatalog.validateForeignCatalog(at: file).photoCount == 0)
    }

    @Test func aCatalogFromANewerVersionIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeCatalog(tamper: "PRAGMA user_version = \(PhotoCatalog.migrations.count + 1)")
        #expect(throws: ForeignCatalogError.newerVersion(PhotoCatalog.migrations.count + 1)) {
            try PhotoCatalog.validateForeignCatalog(at: file)
        }
    }

    /// The same rule decides what `Library.url(for:)` follows.
    @Test func theLibraryNeverFollowsAPathTheValidationReports() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = try Library(root: folder.appendingPathComponent("library"))
        var inside = makePhoto()
        inside.relativePath = "Originals/../catalog.sqlite"
        let photo = try #require(try library.catalog.photo(try library.catalog.add(inside)))
        #expect(!FileManager.default.fileExists(atPath: library.url(for: photo).path))
        #expect(library.url(for: photo).lastPathComponent != "catalog.sqlite")
    }
}
