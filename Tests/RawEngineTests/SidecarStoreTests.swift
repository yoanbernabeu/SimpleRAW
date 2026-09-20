import Foundation
import Testing
@testable import RawEngine

@Suite struct SidecarStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-sidecar-\(UUID().uuidString)")
    var photo: URL { directory.appendingPathComponent("R0001.DNG") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func aPhotoWithoutSidecarHasNoSavedAdjustments() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try SidecarStore().load(for: photo) == nil)
    }

    @Test func savedAdjustmentsComeBack() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidecarStore()
        try store.save(AdjustmentGroupTests.edited, for: photo)
        #expect(try store.load(for: photo) == AdjustmentGroupTests.edited)
    }

    /// Next to the photo, named after the whole file name: a RAW and a JPEG sharing a stem
    /// must not share their settings.
    @Test func theSidecarSitsNextToThePhoto() {
        #expect(SidecarStore().sidecarURL(for: photo).lastPathComponent == "R0001.DNG.simpleraw.json")
        #expect(SidecarStore().sidecarURL(for: photo).deletingLastPathComponent().path == directory.path)
    }

    @Test func aNeutralDocumentLeavesNoFileBehind() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidecarStore()
        try store.save(AdjustmentGroupTests.edited, for: photo)
        try store.save(Adjustments(), for: photo)
        #expect(!FileManager.default.fileExists(atPath: store.sidecarURL(for: photo).path))
    }

    @Test func sidecarsCanBeKeptInADedicatedFolder() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let elsewhere = directory.appendingPathComponent("sidecars")
        let store = SidecarStore(directory: elsewhere)
        try store.save(AdjustmentGroupTests.edited, for: photo)
        #expect(store.sidecarURL(for: photo).deletingLastPathComponent().path == elsewhere.path)
        #expect(try store.load(for: photo) == AdjustmentGroupTests.edited)
    }

    @Test func aDamagedSidecarIsAnErrorNotASilentReset() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidecarStore()
        try Data("garbage".utf8).write(to: store.sidecarURL(for: photo))
        #expect(throws: (any Error).self) { try store.load(for: photo) }
    }
}
