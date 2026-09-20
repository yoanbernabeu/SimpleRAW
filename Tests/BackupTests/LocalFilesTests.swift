import Catalog
import Foundation
import Testing
@testable import Backup

/// Which files of the library go up, and under which keys.
@Suite struct LocalFilesTests {
    let day = "Originals/2026/2026-09-11"

    /// `Originals` on an external disk, linked from the library: keys used to be whatever was
    /// left of an absolute path once as many characters as the root has were cut off.
    @Test func aBackedUpFolderLinkedFromElsewhereIsReportedNotUploaded() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let originals = sandbox.library.root.appendingPathComponent("Originals")
        let external = sandbox.root.appendingPathComponent("external disk/Originals")
        try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originals, to: external)
        try FileManager.default.createSymbolicLink(at: originals, withDestinationURL: external)

        let store = InMemoryObjectStore()
        let report = await LibraryBackup(library: sandbox.library, store: store).run()

        #expect(report.failures.map(\.key) == ["Originals"])
        #expect(report.failures.first?.error as? BackupError == .linkNotBackedUp("Originals"))
        #expect(try await store.list(prefix: "").map(\.key) == ["catalog.sqlite", "catalog.sqlite.sha256"])
    }

    @Test func aLinkInsideABackedUpFolderIsReportedUnlessItLeadsToAFileOfTheLibrary() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let folder = sandbox.library.root.appendingPathComponent(day)
        let outside = sandbox.root.appendingPathComponent("private.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("outside.DNG"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("inside.DNG"), withDestinationURL: folder.appendingPathComponent("a.DNG"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("folder"), withDestinationURL: sandbox.root)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("broken.DNG"), withDestinationURL: folder.appendingPathComponent("gone.DNG"))

        let store = InMemoryObjectStore()
        let report = await LibraryBackup(library: sandbox.library, store: store).run()

        #expect(Set(report.failures.map(\.key)) == ["\(day)/outside.DNG", "\(day)/folder", "\(day)/broken.DNG"])
        #expect(Set(report.uploaded) == ["\(day)/a.DNG", "\(day)/inside.DNG", "catalog.sqlite"])
        let copy = sandbox.root.appendingPathComponent("copy")
        try await store.get("\(day)/inside.DNG", to: copy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "aaa")
        // The size that counts is the file's, not the link's: nothing goes up twice.
        let second = await LibraryBackup(library: sandbox.library, store: store).run()
        #expect(second.uploaded.isEmpty && second.skipped == 3)
    }

    /// Keys are the names of the folders walked through, whatever the library's own path is
    /// made of: a link above it, spaces, accents.
    @Test func aLibraryReachedThroughALinkHasTheSameKeys() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let real = sandbox.root.appendingPathComponent("réelle bibliothèque")
        let link = sandbox.root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let library = try Library(root: link)
        let file = link.appendingPathComponent("\(day)/é è.DNG")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("aaa".utf8).write(to: file)

        let report = await LibraryBackup(library: library, store: InMemoryObjectStore()).run()
        #expect(report.failures.isEmpty)
        #expect(Set(report.uploaded) == ["\(day)/é è.DNG", "catalog.sqlite"])
    }
}
