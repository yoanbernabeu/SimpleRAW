import CoreImage
import CoreImage.CIFilterBuiltins

/// Removes blemishes by cloning: for each spot, the picture shifted so that the source lands
/// on the target, shown through a soft disc. Runs early, so that every other stage works on
/// clean pixels.
public struct SpotRemovalStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite else { return image }
        return adjustments.spots.reduce(image) { current, spot in
            let (target, source) = (spot.target.location(in: extent), spot.source.location(in: extent))
            let shifted = current.transformed(by: CGAffineTransform(translationX: target.x - source.x, y: target.y - source.y))

            let blend = CIFilter.blendWithMask()
            blend.inputImage = shifted
            blend.backgroundImage = current
            blend.maskImage = Self.mask(of: spot, in: extent).image(in: extent)
            return blend.outputImage?.cropped(to: extent) ?? current
        }
    }

    /// A point is a soft disc; a line is a brush stroke drawn along it, which is the same
    /// shape a painted mask has and uses the same rasterizer.
    static func mask(of spot: Spot, in extent: CGRect) -> Mask {
        guard !spot.isLine else {
            return .brush(BrushMask(strokes: [BrushMask.Stroke(points: spot.points, radius: spot.radius)]))
        }
        let longEdge = max(extent.width, extent.height)
        return .radial(RadialMask(
            center: spot.target,
            radiusX: spot.radius * longEdge / extent.width,
            radiusY: spot.radius * longEdge / extent.height,
            feather: spot.feather
        ))
    }
}
