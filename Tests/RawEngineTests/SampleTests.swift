import Foundation
import Testing
import TestSupport

@Suite struct SampleTests {
    /// A git worktree gets its `Samples` as a link to the main checkout's: end-to-end tests
    /// and `make bench` must find the files behind it rather than be skipped in silence.
    @Test func findsTheSamplesBehindASymbolicLink() throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("SampleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let folder = sandbox.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["b.DNG", "a.dng", "notes.txt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        let link = sandbox.appendingPathComponent("Samples")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        #expect(Sample.files(in: link).map(\.lastPathComponent) == ["a.dng", "b.DNG"])
        #expect(Sample.files(in: folder).map(\.lastPathComponent) == ["a.dng", "b.DNG"])
    }

    @Test func aMissingFolderHoldsNoSample() {
        #expect(Sample.files(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).isEmpty)
    }
}
