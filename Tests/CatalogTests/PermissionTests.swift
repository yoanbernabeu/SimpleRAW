import Foundation
import RawEngine
import Testing
@testable import Catalog

/// A library may sit on a shared volume: what it says about its owner (places, dates,
/// keywords, the photos themselves) is for its owner only.
@Suite struct PermissionTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-permissions-\(UUID().uuidString)/library")

    private func permissions(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func aNewLibraryIsPrivateToItsUser() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let library = try Library(root: root)
        try library.catalog.add(makePhoto())
        #expect(try permissions(root) == 0o700)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: root.appendingPathComponent("catalog.sqlite").path + suffix)
            #expect(try permissions(file) == 0o600, "catalog.sqlite\(suffix)")
        }
    }

    /// Exports made into the library are backed up with it. The folder comes with the first
    /// export, private like the rest.
    @Test func theExportsFolderIsMadeOnDemandAndPrivate() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let library = try Library(root: root)
        #expect(!FileManager.default.fileExists(atPath: library.exports.path))
        let folder = try library.preparedExportsFolder()
        #expect(folder == library.exports && folder.lastPathComponent == Library.exportsFolder)
        #expect(try permissions(folder) == 0o700)
    }

    @Test func aCatalogLeftReadableByOthersIsClosedWhenOpened() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("catalog.sqlite")
        do { _ = try Library(root: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = try Library(root: root)
        #expect(try permissions(file) == 0o600)
    }

    /// Someone who shares a folder on purpose keeps it shared: only what the app creates is closed.
    @Test func anExistingFolderKeepsItsPermissions() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try Library(root: root)
        #expect(try permissions(root) == 0o755)
    }

    @Test func theFoldersOfOriginalsAndPreviewsArePrivate() throws {
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let library = try Library(root: root)
        let card = root.deletingLastPathComponent().appendingPathComponent("card")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: card.appendingPathComponent("R0001.DNG"))
        let importer = Importer(library: library) { _ in
            FileMetadata(captureDate: Date(timeIntervalSince1970: 1_789_000_000), camera: nil, lens: nil, iso: nil, exposureTime: nil, aperture: nil, focalLength: nil, width: 1, height: 1)
        }
        let id = try #require(importer.run([card.appendingPathComponent("R0001.DNG")]).imported.first)
        let photo = try #require(try library.catalog.photo(id))
        var folder = library.url(for: photo).deletingLastPathComponent()
        while folder.path != root.path {
            #expect(try permissions(folder) == 0o700, "\(folder.lastPathComponent)")
            folder = folder.deletingLastPathComponent()
        }

        let store = ThumbnailStore(directory: library.previews) { _, _, _, destination in try Data("x".utf8).write(to: destination) }
        let thumbnail = try store.thumbnail(for: photo, original: library.url(for: photo))
        #expect(try permissions(thumbnail.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(library.previews) == 0o700)
    }
}
