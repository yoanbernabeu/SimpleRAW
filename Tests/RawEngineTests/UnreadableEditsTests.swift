import Foundation
import Testing
@testable import RawEngine

/// Edits the app cannot read — a damaged file, or one written by a newer version — are
/// somebody's work. Saving must never destroy them.
@Suite struct UnreadableSidecarTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-unreadable-\(UUID().uuidString)")
    var photo: URL { directory.appendingPathComponent("R0001.DNG") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func siblings() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test(arguments: ["garbage", #"{"version": 99, "exposure": 1.5, "someFutureTool": {"amount": 3}}"#])
    func savingOverWhatCouldNotBeReadSetsItAsideFirst(content: String) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidecarStore()
        try Data(content.utf8).write(to: store.sidecarURL(for: photo))

        var edits = Adjustments()
        edits.contrast = 10
        try store.save(edits, for: photo)

        #expect(try store.load(for: photo) == edits)
        let kept = try #require(siblings().first { $0.contains(".unreadable") })
        #expect(try String(contentsOf: directory.appendingPathComponent(kept), encoding: .utf8) == content)
    }

    @Test func settingAsideTwiceKeepsBoth() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidecarStore()
        for content in ["first", "second"] {
            try Data(content.utf8).write(to: store.sidecarURL(for: photo))
            var edits = Adjustments()
            edits.contrast = 10
            try store.save(edits, for: photo)
        }
        #expect(siblings().filter { $0.contains(".unreadable") }.count == 2)
    }

    @Test func aReadableSidecarIsSimplyReplaced() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidecarStore()
        var edits = Adjustments()
        edits.contrast = 10
        try store.save(edits, for: photo)
        edits.contrast = 20
        try store.save(edits, for: photo)
        #expect(siblings() == ["R0001.DNG.simpleraw.json"])
    }

    /// Going back to neutral deletes the sidecar, but not one that could not be read.
    @Test func resettingDoesNotDeleteWhatCouldNotBeRead() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidecarStore()
        try Data("garbage".utf8).write(to: store.sidecarURL(for: photo))
        try store.save(Adjustments(), for: photo)
        #expect(siblings().contains { $0.contains(".unreadable") })
    }
}
