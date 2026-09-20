import CoreImage
import CoreImage.CIFilterBuiltins

/// Marks what is clipped on the picture itself: red where a channel is burnt out, blue where
/// everything is blocked up. A view aid, never part of an export.
public enum ClippingOverlay {
    /// Display levels beyond which a pixel counts as clipped.
    static let highlightThreshold = 0.995
    static let shadowThreshold = 0.005
    /// How sharply the mark comes on around a threshold.
    private static let steepness = 400.0

    public static func apply(to image: CIImage) -> CIImage {
        guard !image.extent.isInfinite else { return image }
        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = image
        guard let displayed = encode.outputImage else { return image }

        // The brightest channel decides both: burnt as soon as one channel is, blocked only
        // when all of them are.
        let brightest = CIFilter.maximumComponent()
        brightest.inputImage = displayed
        guard let level = brightest.outputImage else { return image }

        let burnt = mask(from: level, scale: steepness, bias: -highlightThreshold * steepness)
        let blocked = mask(from: level, scale: -steepness, bias: shadowThreshold * steepness)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: image.extent)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: image.extent)
        return blend(blue, over: blend(red, over: image, through: burnt), through: blocked).cropped(to: image.extent)
    }

    /// 0 below a threshold, 1 above it: `clamp(level × scale + bias)`.
    private static func mask(from level: CIImage, scale: Double, bias: Double) -> CIImage? {
        let ramp = CIFilter.colorMatrix()
        ramp.inputImage = level
        ramp.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        ramp.gVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        ramp.bVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        ramp.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = ramp.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage
    }

    private static func blend(_ color: CIImage, over image: CIImage, through mask: CIImage?) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = color
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage ?? image
    }
}
