import CoreImage
import CoreImage.CIFilterBuiltins

/// Radial brightness correction: positive amounts lift the corners (lens vignetting, which
/// the decoder does not correct for every camera), negative amounts darken them.
///
/// The gain is `1 + k·r²`, with `r` running from 0 at the center to 1 at the corners. It is a
/// multiplication on linear light, which is what optical falloff is, so the stage must run
/// before any tone mapping.
public struct VignettingStage: PipelineStage {
    /// Correction at the very corner, in stops, for a slider at full scale.
    static let maximumStops = 2.0

    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let amount = Slider.bipolar(adjustments.vignetting)
        guard amount != 0, !image.extent.isInfinite else { return image }
        let cornerGain = pow(2, amount * Self.maximumStops)
        let gain = Self.radialGain(k: cornerGain - 1, over: image.extent)

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = gain
        multiply.backgroundImage = image
        return multiply.outputImage?.cropped(to: image.extent) ?? image
    }

    /// An image worth `1 + k·r²` everywhere, built from stock filters: a linear ramp `r`,
    /// squared, then scaled and offset.
    private static func radialGain(k: Double, over extent: CGRect) -> CIImage? {
        let ramp = CIFilter.radialGradient()
        ramp.center = CGPoint(x: extent.midX, y: extent.midY)
        ramp.radius0 = 0
        ramp.radius1 = Float(hypot(extent.width, extent.height) / 2)
        ramp.color0 = CIColor(red: 0, green: 0, blue: 0)
        ramp.color1 = CIColor(red: 1, green: 1, blue: 1)

        let squared = CIFilter.gammaAdjust()
        squared.inputImage = ramp.outputImage
        squared.power = 2

        return squared.outputImage?.scalingRGB(by: k, bias: 1)
    }
}
