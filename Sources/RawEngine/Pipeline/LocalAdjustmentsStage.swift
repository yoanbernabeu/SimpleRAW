import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies the local adjustments, bottom layer first, each one blended in through its mask.
/// Hidden or fully transparent layers are skipped.
///
/// It sits after the global tone stages and before the creative color ones (curves, HSL,
/// grading), so that a look applies on top of local work rather than under it.
public struct LocalAdjustmentsStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        guard !image.extent.isInfinite else { return image }
        return adjustments.locals.reduce(image) { current, local in
            guard local.hasEffect else { return current }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = local.settings.apply(to: current)
            blend.backgroundImage = current
            blend.maskImage = Self.faded(Self.limited(local.mask.image(in: image.extent), to: local.luminanceRange, of: current), to: local.opacity)
            return blend.outputImage?.cropped(to: image.extent) ?? current
        }
    }

    /// A range of tones is a second mask, read off the picture as the layer finds it: the two
    /// multiply, so that the layer shows where both agree.
    private static func limited(_ mask: CIImage, to range: LuminanceRange?, of image: CIImage) -> CIImage {
        guard let range, !range.isWhole, let tones = range.mask(for: image) else { return mask }
        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = tones
        multiply.backgroundImage = mask
        return multiply.outputImage?.cropped(to: image.extent) ?? mask
    }

    /// Opacity is a weaker mask: the layer shows through less everywhere.
    private static func faded(_ mask: CIImage, to opacity: Double) -> CIImage {
        let share = Slider.unipolar(opacity)
        return mask.scalingRGB(by: share)
    }
}
