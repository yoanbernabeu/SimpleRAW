import Catalog
import Foundation
import Testing
@testable import SimpleRAWUI

@MainActor
@Suite struct LibraryFootprintTests {
    @Test func itCountsThePhotosAndWeighsTheFolder() throws {
        let sandbox = try BackupSessionSandbox()
        defer { sandbox.cleanUp() }
        let before = LibraryFootprint.measure(sandbox.library)
        #expect(before.photoCount == 1 && before.bytes >= 3)

        let export = sandbox.library.root.appendingPathComponent("Exports/deep/a.jpg")
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: export)
        #expect(LibraryFootprint.measure(sandbox.library).bytes == before.bytes + 1000)
    }

    @Test func itIsSaidInOneLine() {
        #expect(LibraryFootprint(photoCount: 1, bytes: 25_000_000).text == "1 photo, 25 MB on disk")
        #expect(LibraryFootprint(photoCount: 12_400, bytes: 310_500_000_000).text == "12,400 photos, 310.5 GB on disk")
    }
}
