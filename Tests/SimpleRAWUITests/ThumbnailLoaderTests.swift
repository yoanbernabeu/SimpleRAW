@testable import Catalog
import CoreGraphics
import Foundation
import ImageIO
import Observation
import RawEngine
import Testing
import UniformTypeIdentifiers
@testable import SimpleRAWUI

/// What the loads of a test did, written from any thread.
private final class LoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: [Int64] = []
    private var running = 0
    private var mostAtOnce = 0

    var order: [Int64] { lock.withLock { loaded } }
    var peak: Int { lock.withLock { mostAtOnce } }

    func begin(_ id: Int64) {
        lock.withLock {
            loaded.append(id)
            running += 1
            mostAtOnce = max(mostAtOnce, running)
        }
    }

    func end() { lock.withLock { running -= 1 } }
}

private func photo(_ id: Int64, contrast: Double = 0) -> Photo {
    var adjustments = Adjustments()
    adjustments.contrast = contrast
    return Photo(
        id: id,
        file: NewPhoto(
            relativePath: "Originals/\(id).DNG", fileName: "\(id).DNG", contentHash: "hash\(id)", captureDate: nil, camera: nil,
            lens: nil, iso: nil, exposureTime: nil, aperture: nil, focalLength: nil, width: 6000, height: 4000
        ),
        importDate: Date(timeIntervalSince1970: 0), rating: 0, flag: .none, colorLabel: nil, adjustments: adjustments,
        isEdited: contrast != 0
    )
}

private func swatch(_ size: Int = 8) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

@MainActor
@Suite struct ThumbnailLoaderTests {
    @Test func aRequestedThumbnailReachesItsSlot() async {
        let loader = ThumbnailLoader { _, _ in swatch() }
        let slot = loader.slot(for: photo(1))
        #expect(slot.image == nil)
        loader.request(photo(1))
        await loader.waitUntilIdle()
        #expect(slot.image != nil && !slot.hasFailed)
        #expect(loader.slot(for: photo(1)) === slot)
    }

    /// A thumbnail that arrives used to invalidate every cell of the grid.
    @Test func aThumbnailThatArrivesOnlyInvalidatesItsOwnCell() async {
        let loader = ThumbnailLoader { _, _ in swatch() }
        let (first, second) = (loader.slot(for: photo(1)), loader.slot(for: photo(2)))
        let firstChanged = Flag(), secondChanged = Flag()
        withObservationTracking { _ = first.image } onChange: { firstChanged.raise() }
        withObservationTracking { _ = second.image } onChange: { secondChanged.raise() }
        loader.request(photo(2))
        await loader.waitUntilIdle()
        #expect(secondChanged.isRaised && !firstChanged.isRaised)
    }

    @Test func thumbnailsLoadInTheOrderTheyWereAskedFor() async {
        let log = LoadLog()
        let loader = ThumbnailLoader(concurrency: 1) { photo, _ in
            log.begin(photo.id)
            defer { log.end() }
            return swatch()
        }
        loader.isSuspended = true
        (1...4).forEach { loader.request(photo($0)) }
        loader.isSuspended = false
        await loader.waitUntilIdle()
        #expect(log.order == [1, 2, 3, 4])
    }

    @Test func noMoreThanAFewLoadAtOnce() async {
        let log = LoadLog()
        let loader = ThumbnailLoader(concurrency: 3) { photo, _ in
            log.begin(photo.id)
            defer { log.end() }
            Thread.sleep(forTimeInterval: 0.01)
            return swatch()
        }
        (1...12).forEach { loader.request(photo($0)) }
        await loader.waitUntilIdle()
        #expect(log.order.count == 12)
        #expect(log.peak <= 3)
    }

    /// A cell that scrolled away before its turn must not cost a RAW development.
    @Test func aCellThatLeftTheScreenIsNotLoaded() async {
        let log = LoadLog()
        let loader = ThumbnailLoader(concurrency: 1) { photo, _ in
            log.begin(photo.id)
            defer { log.end() }
            return swatch()
        }
        loader.isSuspended = true
        (1...3).forEach { loader.request(photo($0)) }
        loader.cancel(2)
        loader.isSuspended = false
        await loader.waitUntilIdle()
        #expect(log.order == [1, 3])
        #expect(loader.slot(for: photo(2)).image == nil)
    }

    @Test func theQueueKeepsTheMostRecentRequestsOnly() async {
        let log = LoadLog()
        let loader = ThumbnailLoader(concurrency: 1, queueLimit: 3) { photo, _ in
            log.begin(photo.id)
            defer { log.end() }
            return swatch()
        }
        loader.isSuspended = true
        (1...10).forEach { loader.request(photo($0)) }
        loader.isSuspended = false
        await loader.waitUntilIdle()
        #expect(log.order == [8, 9, 10])
    }

    /// An unreadable original used to be decoded again every time its cell was drawn.
    @Test func aFailureIsRememberedInsteadOfBeingRetriedForever() async {
        let log = LoadLog()
        let loader = ThumbnailLoader { photo, _ in
            log.begin(photo.id)
            defer { log.end() }
            return nil
        }
        loader.request(photo(1))
        await loader.waitUntilIdle()
        loader.request(photo(1))
        await loader.waitUntilIdle()
        #expect(loader.slot(for: photo(1)).hasFailed)
        #expect(log.order == [1])
    }

    @Test func anEditedPhotoKeepsItsOldThumbnailUntilTheNewOneIsReady() async {
        let log = LoadLog()
        let loader = ThumbnailLoader { photo, _ in
            log.begin(photo.id)
            defer { log.end() }
            return swatch(photo.adjustments.contrast == 0 ? 8 : 16)
        }
        loader.request(photo(1))
        await loader.waitUntilIdle()
        loader.request(photo(1))
        await loader.waitUntilIdle()
        #expect(log.order == [1])

        loader.isSuspended = true
        loader.request(photo(1, contrast: 20))
        #expect(loader.slot(for: photo(1)).image?.width == 8)
        loader.isSuspended = false
        await loader.waitUntilIdle()
        #expect(loader.slot(for: photo(1)).image?.width == 16)
    }

    @Test func nothingStartsWhileTheLoaderIsSuspended() async {
        let log = LoadLog()
        let loader = ThumbnailLoader { photo, _ in
            log.begin(photo.id)
            defer { log.end() }
            return swatch()
        }
        loader.isSuspended = true
        loader.request(photo(1))
        await loader.waitUntilIdle()
        #expect(log.order.isEmpty)
        loader.isSuspended = false
        await loader.waitUntilIdle()
        #expect(log.order == [1])
    }

    /// Coming back to a cell is instant: the decoded image is still in memory, and a cell that
    /// is off screen does not hold on to it.
    @Test func aCellThatComesBackFindsItsThumbnailInMemory() async {
        let log = LoadLog()
        let loader = ThumbnailLoader { photo, _ in
            log.begin(photo.id)
            defer { log.end() }
            return swatch()
        }
        loader.request(photo(1))
        await loader.waitUntilIdle()
        loader.cancel(1)
        #expect(loader.slot(for: photo(1)).image != nil)
        #expect(log.order == [1])
    }

    @Test func aLargerGridAsksForLargerThumbnails() async {
        let sizes = Sizes()
        let loader = ThumbnailLoader { _, size in
            sizes.append(size)
            return swatch()
        }
        loader.pixelSize = 256
        loader.request(photo(1))
        await loader.waitUntilIdle()
        loader.pixelSize = 512
        loader.request(photo(1))
        await loader.waitUntilIdle()
        loader.pixelSize = 256
        loader.request(photo(1))
        await loader.waitUntilIdle()
        #expect(sizes.all == [256, 512])
    }

    /// Thumbnails used to sit side by side in one folder; nothing reads those any more.
    @Test func thumbnailsOfTheOldLayoutAreClearedInTheBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(root: root)
        try FileManager.default.createDirectory(at: library.previews, withIntermediateDirectories: true)
        let legacy = library.previews.appendingPathComponent("12-neutral.jpg")
        try Data("old".utf8).write(to: legacy)

        let loader = ThumbnailLoader(library: library)
        await loader.housekeeping?.value
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func theSizeAskedForFollowsTheCellsUpToWhatIsStored() {
        #expect(ThumbnailLoader.pixelSize(forCellWidth: 110, displayScale: 1) == 256)
        #expect(ThumbnailLoader.pixelSize(forCellWidth: 110, displayScale: 2) == 384)
        #expect(ThumbnailLoader.pixelSize(forCellWidth: 180, displayScale: 2) == 512)
        #expect(ThumbnailLoader.pixelSize(forCellWidth: 360, displayScale: 2) == 512)
    }

    @Test func thumbnailsAreDecodedAtTheSizeTheGridNeeds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("1-neutral.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, swatch(512), nil)
        #expect(CGImageDestinationFinalize(destination))

        let image = try #require(ThumbnailLoader.decode(file, maxPixelSize: 128))
        #expect(max(image.width, image.height) == 128)
        #expect(ThumbnailLoader.decode(folder.appendingPathComponent("missing.jpg"), maxPixelSize: 128) == nil)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

private final class Sizes: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []
    var all: [Int] { lock.withLock { sizes } }
    func append(_ size: Int) { lock.withLock { sizes.append(size) } }
}
