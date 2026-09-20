import Foundation
import Testing
@testable import RawEngine

/// Edits of a photograph that is not in the library, once the app lives in a sandbox.
///
/// Opening `photo.DNG` there gives the right to that one file and nothing else — not to write
/// `photo.DNG.simpleraw.json` beside it, which is a different name in the same folder. So the
/// edits go into the app's own folder, under a fingerprint of the photograph, and the old file
/// beside it is still read when it is there: nobody's work is lost, and nothing has to scan a
/// disk it is no longer allowed to scan.
@Suite struct PrivateEditsTests {
    private func sandbox() throws -> (photos: URL, edits: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let photos = root.appendingPathComponent("Photos")
        let edits = root.appendingPathComponent("Edits")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        return (photos, edits)
    }

    private func photo(_ name: String, in folder: URL, bytes: Int = 64) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test func editsComeBackFromTheAppsOwnFolder() throws {
        let (photos, edits) = try sandbox()
        let file = try photo("R0001.DNG", in: photos)
        let store = SidecarStore.inPrivateFolder(edits)

        var adjustments = Adjustments()
        adjustments.exposure = 1.25
        try store.save(adjustments, for: file)

        #expect(try store.load(for: file)?.exposure == 1.25)
        // And nothing at all beside the photograph: that is the whole point.
        #expect(try FileManager.default.contentsOfDirectory(atPath: photos.path) == ["R0001.DNG"])
    }

    /// Two photographs of the same name, in two folders a person opened one after the other.
    /// Named after the file alone they would share one set of edits.
    @Test func twoPhotographsOfTheSameNameKeepTheirOwnEdits() throws {
        let (photos, edits) = try sandbox()
        let other = photos.appendingPathComponent("Another")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let first = try photo("R0001.DNG", in: photos, bytes: 64)
        let second = try photo("R0001.DNG", in: other, bytes: 128)
        let store = SidecarStore.inPrivateFolder(edits)

        var one = Adjustments()
        one.exposure = 1
        try store.save(one, for: first)
        var two = Adjustments()
        two.exposure = -1
        try store.save(two, for: second)

        #expect(try store.load(for: first)?.exposure == 1)
        #expect(try store.load(for: second)?.exposure == -1)
    }

    /// What an earlier version wrote beside the photograph is still somebody's work.
    @Test func editsWrittenBesideThePhotographAreStillRead() throws {
        let (photos, edits) = try sandbox()
        let file = try photo("R0001.DNG", in: photos)
        var old = Adjustments()
        old.contrast = 30
        try SidecarStore().save(old, for: file)

        #expect(try SidecarStore.inPrivateFolder(edits).load(for: file)?.contrast == 30)
    }

    /// And once it is edited again, the app's own copy is the one that answers: the file
    /// beside the photograph is left alone, because in a sandbox it cannot be touched.
    @Test func theAppsOwnCopyWinsOnceItExists() throws {
        let (photos, edits) = try sandbox()
        let file = try photo("R0001.DNG", in: photos)
        var old = Adjustments()
        old.contrast = 30
        try SidecarStore().save(old, for: file)

        let store = SidecarStore.inPrivateFolder(edits)
        var now = Adjustments()
        now.contrast = -10
        try store.save(now, for: file)

        #expect(try store.load(for: file)?.contrast == -10)
        #expect(try SidecarStore().load(for: file)?.contrast == 30)
    }

    /// A photograph whose fingerprint is asked for twice gives the same answer, and two
    /// different ones do not collide.
    @Test func aFingerprintIsStableAndTellsPhotographsApart() throws {
        let (photos, _) = try sandbox()
        let first = try photo("R0001.DNG", in: photos, bytes: 64)
        let second = try photo("R0002.DNG", in: photos, bytes: 64)
        #expect(PhotoFingerprint.of(first) == PhotoFingerprint.of(first))
        #expect(PhotoFingerprint.of(first) != PhotoFingerprint.of(second))
    }
}
