import CoreImage
import Foundation

/// A mask painted by hand. Strokes are kept as vectors, in frame fractions, so that the mask
/// is the same at any resolution.
public struct BrushMask: Codable, Equatable, Sendable {
    public struct Stroke: Codable, Equatable, Sendable {
        public var points: [NormalizedPoint]
        /// In fractions of the frame's long edge.
        public var radius: Double
        /// An erasing stroke removes what earlier strokes painted.
        public var isErasing: Bool

        public init(points: [NormalizedPoint], radius: Double, isErasing: Bool = false) {
            self.points = points
            self.radius = radius
            self.isErasing = isErasing
        }
    }

    public var strokes: [Stroke] = []

    public init(strokes: [Stroke] = []) {
        self.strokes = strokes
    }

    /// Longest side of the rasterized mask. A mask is soft by nature: it is drawn once at this
    /// size and scaled to whatever size it is asked for, which nobody can see, keeps painting
    /// responsive and lets every reader of the mask share one raster.
    static let maximumRasterSide: CGFloat = 2048
    /// Share of the brush radius over which its edge fades.
    static let softness = 0.5

    /// Strokes are drawn hard (`BrushRasterizer`), then blurred: the soft edge ends up centered
    /// on the radius. One blur for the whole mask, sized on the smallest brush.
    func image(in extent: CGRect, store: BrushRasterStore = .shared) -> CIImage? {
        guard !strokes.isEmpty, extent.width > 0, extent.height > 0, !extent.isInfinite,
              let raster = store.raster(for: self, aspectRatio: Double(extent.width / extent.height)) else { return nil }
        let bounds = CGRect(origin: .zero, size: raster.size)
        let smallest = strokes.map(\.radius).min() ?? 0
        let blur = smallest * max(raster.size.width, raster.size.height) * Self.softness / 2
        return CIImage(cgImage: raster.bitmap).clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: bounds)
            .transformed(by: CGAffineTransform(scaleX: extent.width / raster.size.width, y: extent.height / raster.size.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}
