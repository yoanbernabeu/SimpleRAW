import CoreImage
import Foundation
import RawEngine

/// Renders the open photo with each look, small, off the main actor. It owns a decoder of its
/// own, as the histogram does: the on-screen one is not thread-safe.
actor LookPreviewWorker {
    /// Long edge of a thumbnail, in pixels: two columns in the inspector, on a Retina display.
    private static let size = CGSize(width: 288, height: 288)

    private var source: RawSource?
    private var url: URL?
    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])

    func thumbnails(of url: URL, base: Adjustments, looks: [Preset]) -> [String: CGImage] {
        if self.url != url {
            source = try? RawSource(url: url)
            self.url = url
        }
        guard let source else { return [:] }
        var rendered: [String: CGImage] = [:]
        for look in looks {
            var adjustments = base
            look.apply(to: &adjustments)
            let shown = adjustments.geometry.outputSize(for: source.info.imageSize)
            let scale = PreviewScale.factor(for: shown, fitting: Self.size)
            guard !Task.isCancelled, let image = try? source.image(adjustments: adjustments, scaleFactor: scale) else { continue }
            rendered[look.name] = context.createCGImage(image, from: image.extent)
        }
        return rendered
    }
}
