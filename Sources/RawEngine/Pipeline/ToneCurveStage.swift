import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies the curve computed by `ToneCurve` (contrast, whites, blacks, positive highlights).
public struct ToneCurveStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        guard let points = ToneCurve.points(for: adjustments) else { return image }

        // CIToneCurve already evaluates its points in a perceptual (sRGB-encoded) space, even
        // though the working space is linear. Wrapping it in our own linear ↔ sRGB conversion
        // would apply the encoding twice and shift the pivot far from mid-gray.
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = points[0]
        filter.point1 = points[1]
        filter.point2 = points[2]
        filter.point3 = points[3]
        filter.point4 = points[4]
        return filter.outputImage ?? image
    }
}
