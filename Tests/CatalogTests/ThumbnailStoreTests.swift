import CoreImage
import Foundation
import RawEngine
import TestSupport
import Testing
@testable import Catalog

@Suite struct ThumbnailStoreTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-thumbs-\(UUID().uuidString)")
    let original = URL(fileURLWithPath: "/library/Originals/R0001.DNG")

    private func photo(id: Int64 = 1, contrast: Double = 0) -> Photo {
        var adjustments = Adjustments()
        adjustments.contrast = contrast
        return Photo(id: id, file: makePhoto(), importDate: Date(), rating: 0, flag: .none, colorLabel: nil, adjustments: adjustments, isEdited: contrast != 0)
    }

    /// Counts renders, and writes a recognizable file instead of developing anything.
    private final class Recorder: @unchecked Sendable {
        var renders = 0
    }

    private func store(_ recorder: Recorder, longEdge: Int = ThumbnailStore.defaultLongEdge, renderVersion: Int = ThumbnailStore.renderVersion) -> ThumbnailStore {
        ThumbnailStore(directory: directory, longEdge: longEdge, renderVersion: renderVersion) { _, adjustments, _, destination in
            recorder.renders += 1
            try Data("contrast \(adjustments.contrast)".utf8).write(to: destination)
        }
    }

    @Test func aThumbnailIsRenderedOnceThenServedFromDisk() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        let store = store(recorder)
        #expect(store.cachedURL(for: photo()) == nil)
        let first = try store.thumbnail(for: photo(), original: original)
        let second = try store.thumbnail(for: photo(), original: original)
        #expect(first == second && recorder.renders == 1)
        #expect(store.cachedURL(for: photo()) == first)
    }

    @Test func editingThePhotoMakesANewThumbnailAndDropsTheOldOne() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        let store = store(recorder)
        let before = try store.thumbnail(for: photo(), original: original)
        let after = try store.thumbnail(for: photo(contrast: 30), original: original)
        #expect(before != after && recorder.renders == 2)
        #expect(try String(contentsOf: after, encoding: .utf8) == "contrast 30.0")
        #expect(!FileManager.default.fileExists(atPath: before.path))
    }

    @Test func photosDoNotShareThumbnails() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(Recorder())
        let first = try store.thumbnail(for: photo(id: 1), original: original)
        let second = try store.thumbnail(for: photo(id: 12), original: original)
        #expect(first != second)
        // Dropping photo 1's thumbnails must not touch photo 12's.
        store.removeThumbnails(forPhoto: 1)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    /// Regression: the name only carried the edits, so a thumbnail rendered before a stage
    /// was fixed, or at another size, was served forever.
    @Test func aThumbnailFromAnotherRenderingIsMadeAgainAndDropped() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        let old = try store(recorder, renderVersion: 1).thumbnail(for: photo(), original: original)
        let new = try store(recorder, renderVersion: 2).thumbnail(for: photo(), original: original)
        #expect(old != new && recorder.renders == 2)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func twoSizesOfTheSamePhotoLiveSideBySide() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        let small = try store(recorder, longEdge: 256).thumbnail(for: photo(), original: original)
        let large = try store(recorder, longEdge: 1024).thumbnail(for: photo(), original: original)
        #expect(small != large && recorder.renders == 2)
        #expect(FileManager.default.fileExists(atPath: small.path) && FileManager.default.fileExists(atPath: large.path))
        // Editing replaces the one size that was asked for again, and leaves the other alone.
        _ = try store(recorder, longEdge: 256).thumbnail(for: photo(contrast: 5), original: original)
        #expect(!FileManager.default.fileExists(atPath: small.path) && FileManager.default.fileExists(atPath: large.path))
    }

    /// Tidying up after a render lists one folder: it must hold a slice of the library, not
    /// all of it, or rendering every thumbnail is quadratic.
    @Test func thumbnailsAreSpreadOverFoldersOfAThousandPhotos() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(Recorder())
        let folders = try [1, 999, 1000, 50_000].map { try store.thumbnail(for: photo(id: $0), original: original).deletingLastPathComponent().lastPathComponent }
        #expect(folders == ["0", "0", "1", "50"])
        #expect(try store.url(for: photo(id: 1000)) == store.cachedURL(for: photo(id: 1000)))
    }

    @Test func thumbnailsOfTheFormerFlatLayoutCanBeSweptAway() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(Recorder())
        let kept = try store.thumbnail(for: photo(), original: original)
        let legacy = directory.appendingPathComponent("1-neutral.jpg")
        try Data("old".utf8).write(to: legacy)
        store.removeLegacyThumbnails()
        #expect(!FileManager.default.fileExists(atPath: legacy.path) && FileManager.default.fileExists(atPath: kept.path))
    }

    /// Regression: edits that could not be encoded fell back on the neutral thumbnail, which
    /// showed the photo without them.
    @Test func editsThatCannotBeEncodedNeverBorrowTheNeutralThumbnail() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder()
        let store = store(recorder)
        _ = try store.thumbnail(for: photo(), original: original)
        #expect(store.cachedURL(for: photo(contrast: .nan)) == nil)
        #expect(throws: (any Error).self) { try store.thumbnail(for: photo(contrast: .nan), original: original) }
        #expect(recorder.renders == 1)
    }

    @Test func aFailedRenderLeavesNoFile() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThumbnailStore(directory: directory) { _, _, _, _ in throw RawEngineError.analysisFailed }
        #expect(throws: RawEngineError.analysisFailed) { try store.thumbnail(for: photo(), original: original) }
        #expect(store.cachedURL(for: photo()) == nil)
    }
}

@Suite(.enabled(if: Sample.url != nil, "No DNG in Samples/"))
struct RealThumbnailTests {
    @Test func rendersASmallJPEGWithTheAdjustmentsApplied() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try #require(Sample.url)
        var adjustments = Adjustments()
        adjustments.saturation = -100
        let photo = Photo(id: 1, file: makePhoto(), importDate: Date(), rating: 0, flag: .none, colorLabel: nil, adjustments: adjustments, isEdited: true)

        let url = try ThumbnailStore(directory: directory).thumbnail(for: photo, original: sample)
        let image = try #require(CIImage(contentsOf: url))
        #expect(max(image.extent.width, image.extent.height) == CGFloat(ThumbnailStore.defaultLongEdge))
        #expect(try PixelProbe().average(of: image).chroma < 0.02)
    }
}
