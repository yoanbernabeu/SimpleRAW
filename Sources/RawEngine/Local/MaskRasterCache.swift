import CoreImage
import Foundation

/// What the machine found, kept on disk so that it is found once and not once per opening.
///
/// Asking Vision costs twelve milliseconds a mask, plus loading the model the first time in a
/// launch — not ruinous, but paid again every time a photograph is opened, and a photographer
/// opens the same one twenty times in an evening. What is cached is the picture of the mask,
/// under the id the mask was born with, which is stored in the document and therefore outlives
/// the session.
///
/// Versioned like a thumbnail: **bump `version` whenever a mask is rendered differently**, and
/// everything written before is ignored rather than shown as if it were current. Nothing sweeps
/// the old files, and nothing needs to — a version that is no longer read is a file that is no
/// longer opened, and the folder is small enough to be thrown away whole.
public struct MaskRasterCache {
    /// Bump when the rendering of a found mask changes.
    public static let version = 1

    private let folder: URL
    /// Its own, because writing a PNG must not wait behind whatever the canvas is rendering.
    /// Kept rather than made per call: building one costs milliseconds.
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init(folder: URL) {
        self.folder = folder
    }

    /// Where the app keeps them: inside the container, once the app is wrapped.
    public static var applicationSupport: MaskRasterCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MaskRasterCache(folder: base.appendingPathComponent("SimpleRAW").appendingPathComponent("Masks"))
    }

    public func file(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString)-v\(Self.version).png")
    }

    public func raster(for id: UUID) -> CIImage? {
        let url = file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return CIImage(contentsOf: url)
    }

    /// Written as an ordinary PNG rather than as anything clever. A mask is grey, so three of
    /// its four channels are spent saying the same thing — but a smooth grey compresses to
    /// almost nothing, and a format everything on this machine can open is worth more here
    /// than the bytes.
    public func store(_ raster: CIImage, for id: UUID) {
        guard !raster.extent.isInfinite, let space = CGColorSpace(name: CGColorSpace.linearSRGB) else { return }
        guard let data = context.pngRepresentation(of: raster, format: .RGBA8, colorSpace: space) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(for: id), options: .atomic)
    }

    /// For a mask that is being asked for again: the photographer chose another instance, or
    /// the layer went away.
    public func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }
}
