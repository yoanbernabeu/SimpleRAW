import CoreImage
import Foundation
import RawEngine

/// Develops a picture at full size, off the main actor, for the 100 % view to pan over.
/// It owns a decoder of its own, because the on-screen one is not thread-safe.
actor ZoomCacheWorker {
    private var source: RawSource?
    private var url: URL?
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// 8 bits per channel in the display's color space: a quarter of the memory of half
    /// floats, and indistinguishable on screen at 100 %.
    func develop(_ url: URL, adjustments: Adjustments) -> CGImage? {
        if self.url != url {
            source = try? RawSource(url: url)
            self.url = url
        }
        guard let image = try? source?.image(adjustments: adjustments) else { return nil }
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.colorSpace)
    }
}
