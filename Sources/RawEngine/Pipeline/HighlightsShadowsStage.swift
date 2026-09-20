import CoreImage
import CoreImage.CIFilterBuiltins

/// Adaptive (local) highlight and shadow recovery. Brightening the highlights is
/// `ToneCurveStage`'s job instead.
public struct HighlightsShadowsStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let highlights = min(0, Slider.bipolar(adjustments.highlights))
        let shadows = Slider.bipolar(adjustments.shadows)
        guard highlights != 0 || shadows != 0 else { return image }

        let filter = CIFilter.highlightShadowAdjust()
        filter.inputImage = image
        // Useful range of the filter: 1 (neutral) → 0.3 (maximum recovery).
        filter.highlightAmount = Float(1 + highlights * 0.7)
        filter.shadowAmount = Float(shadows)
        return filter.outputImage ?? image
    }
}
