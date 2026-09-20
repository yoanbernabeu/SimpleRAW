import CoreImage
import CoreImage.CIFilterBuiltins

/// Boosts muted colors first, going easy on the ones that are already vivid.
public struct VibranceStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        guard adjustments.vibrance != 0 else { return image }
        let filter = CIFilter.vibrance()
        filter.inputImage = image
        filter.amount = Float(Slider.bipolar(adjustments.vibrance))
        return filter.outputImage ?? image
    }
}

/// Uniform saturation: -100 yields black and white.
public struct SaturationStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        guard adjustments.saturation != 0 else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = Float(1 + Slider.bipolar(adjustments.saturation))
        return filter.outputImage ?? image
    }
}
