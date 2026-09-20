import Catalog
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// The picture the loupe shows, read off the main actor. The thumbnail of the grid stands in
/// until it is there, a picture that comes late never replaces the current one, the last few
/// stay in memory, and the next photo is read ahead: a cull goes forward.
@MainActor
@Observable
final class LoupeLoader {
    typealias Load = @Sendable (Photo) -> CGImage?

    private(set) var image: CGImage?
    private(set) var photoID: Int64?
    /// The photo could not be read: its original is missing or damaged.
    private(set) var hasFailed = false

    @ObservationIgnored private let load: Load
    @ObservationIgnored private let cache = NSCache<NSString, CachedPicture>()
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var pending = 0
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Long edge of what the loupe shows: enough for a large display, a fraction of a sensor.
    nonisolated static let pixelSize = 2560

    init(load: @escaping Load) {
        self.load = load
        cache.countLimit = 8
    }

    /// An untouched photo shows the JPEG its camera embedded, which costs no development: it
    /// is there at once. An edited one shows its edits, developed once and kept on disk.
    convenience init(library: Library) {
        let store = ThumbnailStore(directory: library.previews, longEdge: Self.pixelSize)
        self.init { photo in
            let original = library.url(for: photo)
            if !photo.isEdited, let embedded = Self.embeddedPreview(of: original, maxPixelSize: Self.pixelSize) { return embedded }
            guard let url = try? store.thumbnail(for: photo, original: original) else { return nil }
            return ThumbnailLoader.decode(url, maxPixelSize: Self.pixelSize)
        }
    }

    /// - Parameters:
    ///   - placeholder: what to show until the picture is read; the thumbnail of the grid.
    ///   - next: the photo to read ahead.
    func show(_ photo: Photo, placeholder: CGImage?, next: Photo? = nil) {
        let key = Self.key(for: photo)
        defer { if let next { read(next, show: false) } }
        guard key != current || photoID != photo.id else { return }
        (current, photoID, hasFailed) = (key, photo.id, false)
        if let cached = cache.object(forKey: key as NSString) {
            image = cached.image
        } else {
            image = placeholder
            read(photo, show: true)
        }
    }

    func clear() {
        (current, photoID, image, hasFailed) = (nil, nil, nil, false)
    }

    /// Returns once nothing is being read. For tests.
    func waitUntilIdle() async {
        guard pending > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func read(_ photo: Photo, show: Bool) {
        let key = Self.key(for: photo)
        guard cache.object(forKey: key as NSString) == nil else { return }
        pending += 1
        let load = load
        Task.detached(priority: show ? .userInitiated : .utility) { [weak self] in
            let image = load(photo)
            await self?.finish(key, image)
        }
    }

    private func finish(_ key: String, _ loaded: CGImage?) {
        if let loaded { cache.setObject(CachedPicture(loaded), forKey: key as NSString) }
        if key == current {
            if let loaded { image = loaded }
            hasFailed = loaded == nil
        }
        pending -= 1
        if pending == 0 {
            idleWaiters.forEach { $0.resume() }
            idleWaiters = []
        }
    }

    /// A photo and the state of its edits: editing it makes another picture.
    private static func key(for photo: Photo) -> String {
        "\(photo.id)-\(ThumbnailLoader.key(for: photo))"
    }

    /// The preview a camera embeds in its RAW files, upright; for a JPEG or a TIFF, the picture
    /// itself, reduced. ImageIO reads it without developing anything.
    nonisolated static func embeddedPreview(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private final class CachedPicture {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
