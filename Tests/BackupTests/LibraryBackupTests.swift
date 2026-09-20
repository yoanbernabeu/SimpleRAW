import Catalog
import Foundation
import Testing
@testable import Backup

/// A library of few-byte "originals", catalogued for real, in a throwaway folder.
struct BackupSandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-backup-\(UUID().uuidString)")
    let library: Library

    init() throws {
        library = try Library(root: root.appendingPathComponent("library"))
    }

    @discardableResult
    func addPhoto(_ name: String, content: String) throws -> Int64 {
        let relativePath = "Originals/2026/2026-09-11/\(name)"
        let file = library.root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
        return try library.catalog.add(NewPhoto(
            relativePath: relativePath, fileName: name, contentHash: BackupHash.sha256(of: file), captureDate: nil,
            camera: "RICOH GR III", lens: nil, iso: 100, exposureTime: 0.01, aperture: 5.6, focalLength: 18.3, width: 6000, height: 4000
        ))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// The scenarios a backup must get right, run against any store: in memory here, and
/// against a real S3 server in `S3BackupIntegrationTests`.
struct BackupScenarios {
    let store: any ObjectStore

    func firstRunUploadsEverythingThenNothing() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        try sandbox.addPhoto("b.DNG", content: "bbb")
        let backup = LibraryBackup(library: sandbox.library, store: store)

        let first = await backup.run()
        #expect(first.failures.isEmpty)
        #expect(Set(first.uploaded) == ["Originals/2026/2026-09-11/a.DNG", "Originals/2026/2026-09-11/b.DNG", "catalog.sqlite"])

        let second = await backup.run()
        #expect(second.uploaded.isEmpty && second.failures.isEmpty)
        #expect(second.skipped == 3)
    }

    func onlyWhatChangedGoesUp() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let id = try sandbox.addPhoto("a.DNG", content: "aaa")
        let backup = LibraryBackup(library: sandbox.library, store: store)
        _ = await backup.run()

        // A rating changes the catalog, not the original.
        try sandbox.library.catalog.setRating(5, for: [id])
        let afterRating = await backup.run()
        #expect(afterRating.uploaded == ["catalog.sqlite"])

        try sandbox.addPhoto("b.DNG", content: "bbb")
        let afterImport = await backup.run()
        #expect(Set(afterImport.uploaded) == ["Originals/2026/2026-09-11/b.DNG", "catalog.sqlite"])
    }

    func exportsAreBackedUpButPreviewsAreNot() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        for (folder, name) in [("Exports", "a.jpg"), ("Previews", "1-neutral.jpg")] {
            let directory = sandbox.library.root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("jpeg".utf8).write(to: directory.appendingPathComponent(name))
        }
        let report = await LibraryBackup(library: sandbox.library, store: store).run()
        #expect(report.uploaded.contains("Exports/a.jpg"))
        #expect(!report.uploaded.contains { $0.hasPrefix("Previews/") })
    }

    /// A backup is not a mirror: what disappears locally stays in the bucket.
    func aLocalDeletionIsNeverPropagated() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let id = try sandbox.addPhoto("a.DNG", content: "aaa")
        let backup = LibraryBackup(library: sandbox.library, store: store)
        _ = await backup.run()

        try FileManager.default.removeItem(at: sandbox.library.root.appendingPathComponent("Originals/2026/2026-09-11/a.DNG"))
        try sandbox.library.catalog.remove([id])
        _ = await backup.run()
        #expect(try await store.list(prefix: "Originals/").map(\.key) == ["Originals/2026/2026-09-11/a.DNG"])
    }

    func aRestoredLibraryIsCompleteAndVerified() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let id = try sandbox.addPhoto("a.DNG", content: "aaa")
        try sandbox.addPhoto("b.DNG", content: "bbb")
        try sandbox.library.catalog.setRating(4, for: [id])
        try sandbox.library.catalog.setKeywords(["street"], for: id)
        _ = await LibraryBackup(library: sandbox.library, store: store).run()

        let destination = sandbox.root.appendingPathComponent("restored")
        let report = try await LibraryBackup.restore(from: store, to: destination)
        #expect(report.downloaded == 3 && report.corrupted.isEmpty && report.missing.isEmpty)

        let restored = try Library(root: destination)
        let photo = try #require(try restored.catalog.photo(id))
        #expect(photo.rating == 4)
        #expect(try restored.catalog.keywords(for: id) == ["street"])
        #expect(try String(contentsOf: restored.url(for: photo), encoding: .utf8) == "aaa")
    }

    /// "Verify Backup": every local file against what the store holds, without downloading it.
    func verificationTellsWhatTheStoreLacksOrHoldsDifferently() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let day = "Originals/2026/2026-09-11"
        for name in ["a", "b", "c"] { try sandbox.addPhoto("\(name).DNG", content: String(repeating: name, count: 3)) }
        let exports = sandbox.library.root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: exports.appendingPathComponent("a.jpg"))
        let backup = LibraryBackup(library: sandbox.library, store: store)
        _ = await backup.run()

        let sound = try await backup.verify()
        #expect(sound == VerificationReport(checked: 5))
        #expect(sound.isSound)

        // Same size, other content: the size alone would not tell.
        try await store.put("\(day)/b.DNG", data: Data("BBB".utf8))
        try await store.put("\(day)/c.DNG", data: Data("cc".utf8))
        try await store.put("Exports/a.jpg", data: Data("JPEG".utf8))
        try sandbox.addPhoto("d.DNG", content: "ddd")

        let report = try await backup.verify()
        #expect(report.checked == 6 && !report.isSound)
        #expect(report.missing == ["\(day)/d.DNG"])
        #expect(report.sizeMismatches == ["\(day)/c.DNG"])
        #expect(report.fingerprintMismatches == ["Exports/a.jpg", "\(day)/b.DNG"])
        #expect(report.withoutFingerprint.isEmpty && report.unverified.isEmpty)
    }

    /// An original that is gone from the disk is still in the catalog, and the catalog knows
    /// its fingerprint: the copy in the store can be vouched for.
    func verificationVouchesForOriginalsThatAreNoLongerOnDisk() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let backup = LibraryBackup(library: sandbox.library, store: store)
        _ = await backup.run()
        try FileManager.default.removeItem(at: sandbox.library.root.appendingPathComponent("Originals/2026/2026-09-11/a.DNG"))

        #expect(try await backup.verify() == VerificationReport(checked: 2))
        try await store.put("Originals/2026/2026-09-11/a.DNG", data: Data("tampered".utf8))
        #expect(try await backup.verify().fingerprintMismatches == ["Originals/2026/2026-09-11/a.DNG"])
    }

    func restoringRefusesToOverwriteAnExistingLibrary() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        _ = await LibraryBackup(library: sandbox.library, store: store).run()
        await #expect(throws: BackupError.self) {
            try await LibraryBackup.restore(from: store, to: sandbox.library.root)
        }
    }
}

@Suite struct LibraryBackupTests {
    private var scenarios: BackupScenarios { BackupScenarios(store: InMemoryObjectStore()) }

    @Test func firstRunUploadsEverythingThenNothing() async throws { try await scenarios.firstRunUploadsEverythingThenNothing() }
    @Test func onlyWhatChangedGoesUp() async throws { try await scenarios.onlyWhatChangedGoesUp() }
    @Test func exportsAreBackedUpButPreviewsAreNot() async throws { try await scenarios.exportsAreBackedUpButPreviewsAreNot() }
    @Test func aLocalDeletionIsNeverPropagated() async throws { try await scenarios.aLocalDeletionIsNeverPropagated() }
    @Test func aRestoredLibraryIsCompleteAndVerified() async throws { try await scenarios.aRestoredLibraryIsCompleteAndVerified() }
    @Test func restoringRefusesToOverwriteAnExistingLibrary() async throws { try await scenarios.restoringRefusesToOverwriteAnExistingLibrary() }
    @Test func verificationTellsWhatTheStoreLacksOrHoldsDifferently() async throws { try await scenarios.verificationTellsWhatTheStoreLacksOrHoldsDifferently() }
    @Test func verificationVouchesForOriginalsThatAreNoLongerOnDisk() async throws { try await scenarios.verificationVouchesForOriginalsThatAreNoLongerOnDisk() }

    /// Objects uploaded before fingerprints were: nothing can be said of their content
    /// without downloading them, and that is said rather than guessed.
    @Test func anObjectWithoutAFingerprintIsToldApart() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let store = InMemoryObjectStore()
        store.putWithoutFingerprint("Originals/2026/2026-09-11/a.DNG", data: Data("aaa".utf8))
        let backup = LibraryBackup(library: sandbox.library, store: store)
        _ = await backup.run()

        let report = try await backup.verify()
        #expect(report.withoutFingerprint == ["Originals/2026/2026-09-11/a.DNG"])
        #expect(report.checked == 2 && report.isSound)
    }

    @Test func aStoreThatCannotBeListedFailsTheVerification() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let store = UntrustedStore(base: InMemoryObjectStore(), failsToList: true)
        await #expect(throws: BackupError.self) { try await LibraryBackup(library: sandbox.library, store: store).verify() }
    }

    @Test func everyUploadCarriesItsFingerprint() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let store = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: store).run()
        #expect(try await store.head("Originals/2026/2026-09-11/a.DNG")?.sha256 == BackupHash.sha256(of: Data("aaa".utf8)))
        #expect(try await store.head("catalog.sqlite")?.sha256?.count == 64)
        #expect(try await store.head("nope") == nil)
    }

    /// Regression: the snapshot and its fingerprint were two separate reads of the live
    /// catalog. A write in between gave a fingerprint that did not describe what was uploaded,
    /// and the next run then skipped a catalog that had in fact changed.
    @Test func theStoredFingerprintDescribesTheCatalogThatWasUploaded() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let id = try sandbox.addPhoto("a.DNG", content: "aaa")
        try sandbox.library.catalog.setRating(3, for: [id])
        let store = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: store).run()

        let uploaded = sandbox.root.appendingPathComponent("uploaded.sqlite")
        let hashFile = sandbox.root.appendingPathComponent("uploaded.sha256")
        try await store.get("catalog.sqlite", to: uploaded)
        try await store.get("catalog.sqlite.sha256", to: hashFile)
        #expect(try PhotoCatalog.contentFingerprint(ofCatalogAt: uploaded) == String(contentsOf: hashFile, encoding: .utf8))
    }

    @Test func oneFailingFileDoesNotStopTheOthers() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        try sandbox.addPhoto("b.DNG", content: "bbb")
        let store = InMemoryObjectStore(failingKeys: ["Originals/2026/2026-09-11/a.DNG"])
        let report = await LibraryBackup(library: sandbox.library, store: store).run()
        #expect(report.failures.map(\.key) == ["Originals/2026/2026-09-11/a.DNG"])
        #expect(report.uploaded.contains("Originals/2026/2026-09-11/b.DNG"))
        // The next run picks up where this one stopped.
        let retry = await LibraryBackup(library: sandbox.library, store: InMemoryObjectStore(adopting: store)).run()
        #expect(retry.uploaded.contains("Originals/2026/2026-09-11/a.DNG") && retry.failures.isEmpty)
    }

    @Test func aDamagedOriginalIsReportedOnRestore() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let store = InMemoryObjectStore()
        _ = await LibraryBackup(library: sandbox.library, store: store).run()
        try await store.put("Originals/2026/2026-09-11/a.DNG", data: Data("tampered".utf8))

        let report = try await LibraryBackup.restore(from: store, to: sandbox.root.appendingPathComponent("restored"))
        #expect(report.corrupted == ["Originals/2026/2026-09-11/a.DNG"])
    }

    /// Once before anything is sent, then each time a file is done: it ends on the total.
    @Test func progressIsReportedFileByFile() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let recorder = ProgressRecorder()
        _ = await LibraryBackup(library: sandbox.library, store: InMemoryObjectStore()).run { recorder.record($0) }
        #expect(recorder.totals == [2, 2, 2] && recorder.done == [0, 1, 2])
    }

    /// A round trip per file, one after the other, is what makes a first backup take the night.
    @Test func aFewFilesGoUpAtOnceAndProgressStillCounts() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        for index in 1...12 { try sandbox.addPhoto("\(index).DNG", content: "photo \(index)") }
        let store = ProbeStore()
        let recorder = ProgressRecorder()

        let report = await LibraryBackup(library: sandbox.library, store: store).run { recorder.record($0) }

        #expect((2...4).contains(store.mostAtOnce))
        // A run cut short must not leave a catalog that speaks of originals still on their way.
        #expect(store.started.count == 13 && store.started.last == "catalog.sqlite")
        #expect(report.uploaded.count == 13 && report.failures.isEmpty)
        // Whatever order they finish in, the report is in the order of the keys.
        #expect(report.uploaded == report.uploaded.filter { $0 != "catalog.sqlite" }.sorted() + ["catalog.sqlite"])
        #expect(recorder.done == Array(0...13) && Set(recorder.totals) == [13])
    }

    @Test func failuresAmongConcurrentUploadsAreAllReported() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        let day = "Originals/2026/2026-09-11"
        for index in 1...9 { try sandbox.addPhoto("\(index).DNG", content: "photo \(index)") }
        let failing: Set = ["\(day)/2.DNG", "\(day)/5.DNG", "\(day)/6.DNG"]
        let recorder = ProgressRecorder()

        let report = await LibraryBackup(library: sandbox.library, store: InMemoryObjectStore(failingKeys: failing)).run { recorder.record($0) }

        #expect(Set(report.failures.map(\.key)) == failing)
        #expect(report.uploaded.count == 7)
        #expect(recorder.done.last == 10)
    }

    @Test func verificationAsksAboutAFewObjectsAtOnce() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        for index in 1...8 { try sandbox.addPhoto("\(index).DNG", content: "photo \(index)") }
        let store = ProbeStore()
        let backup = LibraryBackup(library: sandbox.library, store: store)
        _ = await backup.run()
        let recorder = ProgressRecorder()

        let report = try await backup.verify { recorder.record($0) }

        #expect(report == VerificationReport(checked: 9))
        #expect(store.heads == 8 && (2...4).contains(store.mostAtOnce))
        #expect(recorder.done == Array(0...8))
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var done: [Int] = []
    private(set) var totals: [Int] = []

    func record(_ progress: BackupProgress) {
        lock.withLock {
            done.append(progress.done)
            totals.append(progress.total)
        }
    }
}

@Suite(.enabled(if: S3TestServer.configuration != nil, "No S3 server: run `make test-s3`"), .serialized)
struct S3BackupIntegrationTests {
    private func scenarios() async throws -> BackupScenarios {
        let client = try #require(S3TestServer.client(prefix: "backup-tests-\(UUID().uuidString)"))
        try await client.createBucketIfNeeded()
        return BackupScenarios(store: client)
    }

    @Test func firstRunUploadsEverythingThenNothing() async throws { try await scenarios().firstRunUploadsEverythingThenNothing() }
    @Test func onlyWhatChangedGoesUp() async throws { try await scenarios().onlyWhatChangedGoesUp() }
    @Test func exportsAreBackedUpButPreviewsAreNot() async throws { try await scenarios().exportsAreBackedUpButPreviewsAreNot() }
    @Test func aLocalDeletionIsNeverPropagated() async throws { try await scenarios().aLocalDeletionIsNeverPropagated() }
    @Test func aRestoredLibraryIsCompleteAndVerified() async throws { try await scenarios().aRestoredLibraryIsCompleteAndVerified() }
    @Test func verificationTellsWhatTheStoreLacksOrHoldsDifferently() async throws { try await scenarios().verificationTellsWhatTheStoreLacksOrHoldsDifferently() }
    @Test func verificationVouchesForOriginalsThatAreNoLongerOnDisk() async throws { try await scenarios().verificationVouchesForOriginalsThatAreNoLongerOnDisk() }
}
