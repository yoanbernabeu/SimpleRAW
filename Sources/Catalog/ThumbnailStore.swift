import Foundation
import RawEngine

/// Small JPEGs of the photos, as developed, cached on disk. A thumbnail's file name carries
/// everything it depends on: the photo, a fingerprint of its adjustments, its size and the
/// version of the rendering. Editing a photo, or fixing a stage, invalidates thumbnails by
/// itself: there is no state to keep in sync.
public struct ThumbnailStore: Sendable {
    public typealias Render = @Sendable (_ original: URL, _ adjustments: Adjustments, _ longEdge: Int, _ destination: URL) throws -> Void

    public static let defaultLongEdge = 512
    /// Bump when the same adjustments no longer develop into the same picture (a stage was
    /// fixed, the pipeline reordered): every thumbnail is then made again as it is asked for.
    public static let renderVersion = 1
    /// Photos per folder. Tidying up lists one folder: it must not be the whole library.
    static let photosPerFolder: Int64 = 1000

    public let directory: URL
    private let longEdge: Int
    private let renderVersion: Int
    private let render: Render

    /// - Parameter render: how to develop a thumbnail; the engine, unless a test says otherwise.
    public init(
        directory: URL, longEdge: Int = ThumbnailStore.defaultLongEdge, renderVersion: Int = ThumbnailStore.renderVersion,
        render: @escaping Render = ThumbnailStore.develop
    ) {
        self.directory = directory
        self.longEdge = longEdge
        self.renderVersion = renderVersion
        self.render = render
    }

    /// Where the thumbnail of the photo as it is now is, or will be. Touches no disk: a name
    /// is enough to tell whether the thumbnail already on screen is still the right one.
    /// - Throws: if the photo's edits cannot be encoded: they must not borrow another thumbnail.
    public func url(for photo: Photo) throws -> URL {
        folder(forPhoto: photo.id).appendingPathComponent("\(photo.id)-\(try photo.adjustmentsFingerprint)-\(suffix)")
    }

    /// The thumbnail of the photo as it is now, if it has been rendered already.
    public func cachedURL(for photo: Photo) -> URL? {
        guard let url = try? url(for: photo) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The thumbnail of the photo as it is now, rendered if need be. Older thumbnails of the
    /// same photo at this size are dropped.
    public func thumbnail(for photo: Photo, original: URL) throws -> URL {
        if let cached = cachedURL(for: photo) { return cached }
        let destination = try url(for: photo)
        try FileManager.default.createPrivateDirectory(at: destination.deletingLastPathComponent())
        do {
            try render(original, photo.adjustments, longEdge, destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // Another size is another cache and stays; another rendering, of any size, is stale.
        removeThumbnails(forPhoto: photo.id, except: destination) { $0?.longEdge == longEdge || $0?.renderVersion != renderVersion }
        return destination
    }

    /// Every thumbnail of the photo, whatever its size.
    public func removeThumbnails(forPhoto id: Int64, except kept: URL? = nil) {
        removeThumbnails(forPhoto: id, except: kept) { _ in true }
    }

    /// Thumbnails used to sit side by side in `directory`. Nothing reads them any more: call
    /// this once, off the main thread, to get the space back.
    public func removeLegacyThumbnails() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jpg" { try? FileManager.default.removeItem(at: file) }
    }

    /// - Parameter isStale: given what the name of a file says, `nil` if it says nothing.
    private func removeThumbnails(forPhoto id: Int64, except kept: URL?, where isStale: (FileName?) -> Bool) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(forPhoto: id), includingPropertiesForKeys: nil)) ?? []
        // Compared by name: the same folder can be spelled /var/… or /private/var/….
        for file in files where file.lastPathComponent.hasPrefix("\(id)-") && file.lastPathComponent != kept?.lastPathComponent {
            if isStale(FileName(file.lastPathComponent)) { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// `<photo>-<fingerprint>-<long edge>-r<render version>.jpg`, read back.
    private struct FileName {
        let longEdge: Int
        let renderVersion: Int

        init?(_ name: String) {
            let parts = name.dropLast(".jpg".count).split(separator: "-")
            guard name.hasSuffix(".jpg"), parts.count == 4, let longEdge = Int(parts[2]),
                  parts[3].hasPrefix("r"), let renderVersion = Int(parts[3].dropFirst()) else { return nil }
            self.longEdge = longEdge
            self.renderVersion = renderVersion
        }
    }

    /// `<long edge>-r<render version>.jpg`.
    private var suffix: String { "\(longEdge)-r\(renderVersion).jpg" }

    private func folder(forPhoto id: Int64) -> URL {
        directory.appendingPathComponent("\(id / Self.photosPerFolder)")
    }

    /// Decoded at a fraction of the sensor resolution: a thumbnail needs a few hundred pixels.
    public static let develop: Render = { original, adjustments, longEdge, destination in
        let source = try RawSource(url: original)
        let shown = adjustments.geometry.outputSize(for: source.info.imageSize)
        // Twice the target size, so that the final Lanczos downscale has something to work with.
        let scale = PreviewScale.factor(for: shown, fitting: CGSize(width: longEdge * 2, height: longEdge * 2))
        var options = ExportOptions()
        options.longEdge = longEdge
        options.quality = 0.8
        try Renderer.shared.writeJPEG(source.image(adjustments: adjustments, scaleFactor: scale), to: destination, options: options)
    }
}
