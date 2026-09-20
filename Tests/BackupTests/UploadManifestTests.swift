import Catalog
import Foundation
import Testing
@testable import Backup

/// Listing a bucket of 50 000 objects is fifty requests, paid for, before a run has sent
/// anything. A manifest next to the library remembers what previous runs put in the store.
@Suite struct UploadManifestTests {
    let day = "Originals/2026/2026-09-11"

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(days: Double) { lock.withLock { date += days * 86_400 } }
    }

    private func manifest(in sandbox: BackupSandbox, destination: String = "https://s3.example.com|photos|simpleraw", clock: Clock = Clock()) -> UploadManifest {
        UploadManifest(file: sandbox.root.appendingPathComponent("backup-manifest.json"), destination: destination, now: { clock.now })
    }

    @Test func withoutAManifestEveryRunListsTheStore() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let store = ProbeStore()
        for _ in 1...2 { _ = await LibraryBackup(library: sandbox.library, store: store).run() }
        #expect(store.listings == 2)
    }

    @Test func withAManifestOnlyTheFirstRunListsTheStore() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let store = ProbeStore()
        let backup = LibraryBackup(library: sandbox.library, store: store, manifest: manifest(in: sandbox))

        let first = await backup.run()
        #expect(Set(first.uploaded) == ["\(day)/a.DNG", "catalog.sqlite"])
        let second = await backup.run()
        #expect(second.uploaded.isEmpty && second.skipped == 2 && second.failures.isEmpty)

        try sandbox.addPhoto("b.DNG", content: "bbb")
        let third = await backup.run()
        #expect(Set(third.uploaded) == ["\(day)/b.DNG", "catalog.sqlite"])
        #expect(await backup.run().uploaded.isEmpty)
        #expect(store.listings == 1)
    }

    /// What was sent to one bucket says nothing of another.
    @Test func aManifestWrittenForAnotherDestinationIsNotBelieved() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        _ = await LibraryBackup(library: sandbox.library, store: InMemoryObjectStore(), manifest: manifest(in: sandbox)).run()

        let elsewhere = ProbeStore()
        let report = await LibraryBackup(library: sandbox.library, store: elsewhere, manifest: manifest(in: sandbox, destination: "https://s3.example.com|other|simpleraw")).run()
        #expect(elsewhere.listings == 1)
        #expect(Set(report.uploaded) == ["\(day)/a.DNG", "catalog.sqlite"])
    }

    /// A memory is checked against the store now and then: a week is the most it is trusted for.
    @Test func anOldManifestIsCheckedAgainstTheStore() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let (store, clock) = (ProbeStore(), Clock())
        let backup = LibraryBackup(library: sandbox.library, store: store, manifest: manifest(in: sandbox, clock: clock))
        _ = await backup.run()
        clock.advance(days: 6)
        _ = await backup.run()
        #expect(store.listings == 1)
        clock.advance(days: 2)
        _ = await backup.run()
        #expect(store.listings == 2)
        // And it is good for another week.
        clock.advance(days: 6)
        _ = await backup.run()
        #expect(store.listings == 2)
    }

    /// After a failure nobody knows what the store holds: the next run asks it.
    @Test func aFailedUploadMakesTheNextRunListTheStore() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        try sandbox.addPhoto("b.DNG", content: "bbb")
        let failing = InMemoryObjectStore(failingKeys: ["\(day)/a.DNG"])
        let first = await LibraryBackup(library: sandbox.library, store: ProbeStore(base: failing), manifest: manifest(in: sandbox)).run()
        #expect(first.failures.count == 1)

        let recovered = ProbeStore(base: InMemoryObjectStore(adopting: failing))
        let retry = await LibraryBackup(library: sandbox.library, store: recovered, manifest: manifest(in: sandbox)).run()
        #expect(recovered.listings == 1)
        #expect(retry.uploaded == ["\(day)/a.DNG"] && retry.failures.isEmpty)
    }

    @Test(arguments: ["", "not json", "{\"version\": 99}", "[1, 2]"])
    func aManifestThatCannotBeReadIsNotBelieved(content: String) async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let manifest = manifest(in: sandbox)
        try Data(content.utf8).write(to: manifest.file)
        let store = ProbeStore()
        let backup = LibraryBackup(library: sandbox.library, store: store, manifest: manifest)
        #expect(await backup.run().uploaded.count == 2)
        _ = await backup.run()
        #expect(store.listings == 1)
    }

    /// The price of not listing: what disappears from the store goes unnoticed until the
    /// manifest is a week old, or until "Verify Backup", which rewrites it from the store.
    @Test func verifyingBringsTheManifestBackToWhatTheStoreHolds() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let manifest = manifest(in: sandbox)
        _ = await LibraryBackup(library: sandbox.library, store: InMemoryObjectStore(), manifest: manifest).run()

        // The same destination, emptied behind our back.
        let emptied = ProbeStore()
        let backup = LibraryBackup(library: sandbox.library, store: emptied, manifest: manifest)
        // The catalog is the one object a run always asks about; the original is believed there.
        #expect(await backup.run().uploaded == ["catalog.sqlite"])

        let report = try await backup.verify()
        #expect(report.missing == ["\(day)/a.DNG"])
        let repaired = await backup.run()
        #expect(repaired.uploaded == ["\(day)/a.DNG"])
        #expect(try await backup.verify().isSound)
    }

    @Test func aManifestHoldsKeysAndSizesAndNothingElse() async throws {
        let sandbox = try BackupSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.addPhoto("a.DNG", content: "aaa")
        let manifest = manifest(in: sandbox)
        _ = await LibraryBackup(library: sandbox.library, store: InMemoryObjectStore(), manifest: manifest).run()

        let remembered = try #require(manifest.remembered())
        #expect(remembered.objects["\(day)/a.DNG"] == 3)
        #expect(Set(remembered.objects.keys) == ["\(day)/a.DNG", "catalog.sqlite"])
        // Not in a backed-up folder: the manifest never goes up itself.
        #expect(UploadManifest.defaultFile(in: sandbox.library).deletingLastPathComponent().path == sandbox.library.root.path)
    }

    @Test func aConfigurationNamesItsDestination() {
        let one = S3Configuration(endpoint: URL(string: "https://s3.example.com")!, region: "eu-west-3", bucket: "photos", prefix: "/simpleraw/")
        var other = one
        #expect(one.destinationIdentity == "https://s3.example.com|photos|simpleraw")
        other.bucket = "other"
        #expect(one.destinationIdentity != other.destinationIdentity)
        other = one
        other.region = "us-east-1"
        #expect(one.destinationIdentity == other.destinationIdentity)
    }
}
