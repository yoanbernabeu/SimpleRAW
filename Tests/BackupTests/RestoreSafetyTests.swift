import Catalog
import Foundation
import Testing
@testable import Backup

/// A backup store is not trusted: a compromised bucket must not be able to write, or delete,
/// anything outside of the folder a restore was pointed at.
@Suite struct RestoreSafetyTests {
    @Test(arguments: [
        "../evil.txt", "Originals/../../evil.txt", "/etc/evil", "Originals//a.DNG", "Originals/./a.DNG",
        "Originals/..", "~/evil", "Previews/1.jpg", "catalog.sqlite/../../x", "", "Originals/", "Originals/a\u{0}b.DNG",
    ])
    func hostileOrUnexpectedKeysAreRefused(key: String) {
        let root = URL(fileURLWithPath: "/tmp/restore-root")
        #expect(LibraryBackup.safeDestination(forKey: key, in: root) == nil)
    }

    @Test(arguments: ["catalog.sqlite", "Originals/2026/2026-09-11/R0001.DNG", "Exports/web/a b.jpg", "Originals/été/Ünï.DNG"])
    func whatABackupWritesIsAccepted(key: String) throws {
        let root = URL(fileURLWithPath: "/tmp/restore-root")
        let destination = try #require(LibraryBackup.safeDestination(forKey: key, in: root))
        #expect(destination.path == "/tmp/restore-root/" + key)
    }

    @Test func aRestoreSkipsHostileKeysAndSaysSo() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let store = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: store).run()
        try await store.put("../escaped.txt", data: Data("x".utf8))
        try await store.put("Originals/../../escaped-too.txt", data: Data("x".utf8))

        let destination = sandbox.root.appendingPathComponent("restored")
        let report = try await LibraryBackup.restore(from: store, to: destination)

        #expect(Set(report.rejected) == ["../escaped.txt", "Originals/../../escaped-too.txt"])
        #expect(report.downloaded == 2)
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("escaped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.deletingLastPathComponent().appendingPathComponent("escaped-too.txt").path))
    }

    /// What comes down is what the listing announced: a store does not get to fill the disk,
    /// or to hand over half a file, under the name of a photo.
    @Test func aDownloadOfAnotherSizeThanAnnouncedIsNotKept() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        try sandbox.addPhoto("b.DNG", content: "bbb")
        let honest = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: honest).run()
        let key = "Originals/2026/2026-09-11/a.DNG"
        let store = UntrustedStore(base: honest, listing: { $0.map { $0.key == key ? S3Object(key: $0.key, size: 2, etag: $0.etag) : $0 } })

        let destination = sandbox.root.appendingPathComponent("restored")
        let report = try await LibraryBackup.restore(from: store, to: destination)

        #expect(report.failures.map(\.key) == [key])
        #expect(report.failures.first?.reason.contains("3 bytes") == true)
        #expect(report.downloaded == 2 && report.missing == [key])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(key).path))
    }

    /// Like a run: one file failing never stops the others, and the report says which.
    @Test func aDownloadThatFailsDoesNotStopTheOthers() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        for name in ["a", "b", "c"] { try sandbox.addPhoto("\(name).DNG", content: name) }
        let honest = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: honest).run()
        let key = "Originals/2026/2026-09-11/a.DNG"
        let store = UntrustedStore(base: honest, failingDownloads: [key])

        let report = try await LibraryBackup.restore(from: store, to: sandbox.root.appendingPathComponent("restored"))

        #expect(report.failures == [RestoreFailure(key: key, reason: BackupError.storeUnavailable(key).localizedDescription)])
        #expect(report.downloaded == 3 && report.missing == [key] && report.corrupted.isEmpty)
    }

    @Test func withoutItsCatalogARestoreStopsBeforeWritingAnything() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let honest = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: honest).run()
        let store = UntrustedStore(base: honest, failingDownloads: ["catalog.sqlite"])

        let destination = sandbox.root.appendingPathComponent("restored")
        await #expect(throws: BackupError.storeUnavailable("catalog.sqlite")) { try await LibraryBackup.restore(from: store, to: destination) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).isEmpty)
    }

    /// The catalog that comes down was written by whoever holds the bucket. It is checked
    /// before it is opened as a library: a trigger in it would run inside the app.
    @Test func aCatalogTheAppDidNotWriteStopsTheRestore() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let store = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: store).run()

        let tampered = sandbox.root.appendingPathComponent("tampered.sqlite")
        try sandbox.library.catalog.snapshot(to: tampered)
        do {
            let database = try Database(url: tampered)
            try database.execute("CREATE TRIGGER steal AFTER UPDATE ON photos BEGIN DELETE FROM albums; END")
            // Everything in the one file that goes up, as in a snapshot.
            try database.execute("PRAGMA journal_mode = DELETE")
        }
        try await store.put("catalog.sqlite", file: tampered)

        let destination = sandbox.root.appendingPathComponent("restored")
        await #expect { try await LibraryBackup.restore(from: store, to: destination) } throws: { error in
            if case ForeignCatalogError.unexpectedSchema = error { true } else { false }
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).isEmpty)
    }

    @Test func aCatalogOfAnotherSizeThanAnnouncedStopsTheRestore() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let honest = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: honest).run()
        let store = UntrustedStore(base: honest, listing: { $0.map { $0.key == "catalog.sqlite" ? S3Object(key: $0.key, size: 1, etag: $0.etag) : $0 } })

        let destination = sandbox.root.appendingPathComponent("restored")
        await #expect(throws: BackupError.self) { try await LibraryBackup.restore(from: store, to: destination) }
        // Nothing is left behind, so that the restore can be tried again.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).isEmpty)
    }

    /// A restored catalog is untrusted too: a photo whose path leaves the library must not
    /// make the app read, export or trash a file somewhere else.
    @Test func aPhotoWhosePathLeavesTheLibraryResolvesToNothing() throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let id = try sandbox.library.catalog.add(NewPhoto(
            relativePath: "../../../etc/hosts", fileName: "hosts", contentHash: "h", captureDate: nil, camera: nil, lens: nil,
            iso: nil, exposureTime: nil, aperture: nil, focalLength: nil, width: 1, height: 1
        ))
        let photo = try #require(try sandbox.library.catalog.photo(id))
        let url = sandbox.library.url(for: photo)
        #expect(url.standardizedFileURL.path.hasPrefix(sandbox.library.root.standardizedFileURL.path + "/"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
