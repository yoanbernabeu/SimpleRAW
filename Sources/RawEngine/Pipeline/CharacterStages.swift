import CoreImage
import CoreImage.CIFilterBuiltins

/// Shared by the stages below: every radius is a share of the picture's long edge, so that a
/// preview decoded at a quarter of the resolution looks like the full-size export.
private extension CIImage {
    func radius(_ share: Double) -> Float {
        Float(share * max(extent.width, extent.height))
    }

    /// Local contrast at several scales at once. Two things keep it natural: it works on
    /// display-referred values, because in linear light the overshoot next to a bright edge is
    /// huge and reads as a halo; and it touches luminance only, because sharpening channels
    /// separately lets them clip apart and tints those halos. All the scales share one round
    /// trip to display-referred values: converting back and forth per scale cost a frame's
    /// worth of passes for nothing.
    /// Negative amounts blend toward the blurred picture instead, which softens.
    func localContrast(_ scales: [LocalContrastScale]) -> CIImage {
        let active = scales.filter { $0.amount != 0 }
        guard !active.isEmpty else { return self }

        var softened = self
        for scale in active where scale.amount < 0 {
            let blurred = softened.clampedToExtent().applyingGaussianBlur(sigma: Double(radius(scale.radiusShare)) / 2).cropped(to: extent)
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = softened
            mix.targetImage = blurred
            mix.time = Float(-scale.amount) * 0.6
            softened = mix.outputImage?.cropped(to: extent) ?? softened
        }
        let sharpening = active.filter { $0.amount > 0 }
        guard !sharpening.isEmpty else { return softened }

        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = softened.clampedToExtent()
        var current = encode.outputImage
        // Large scales first: fine detail is then sharpened on top of the presence it sits in.
        for scale in sharpening.sorted(by: { $0.radiusShare > $1.radiusShare }) {
            current = current.map { Self.addingPresence($0, radius: radius(scale.radiusShare), sharpness: Float(scale.amount) * scale.strength, extent: extent) }
        }
        let decode = CIFilter.sRGBToneCurveToLinear()
        decode.inputImage = current
        return decode.outputImage?.cropped(to: extent) ?? softened
    }
}

extension CIImage {
    /// One scale of presence, added.
    ///
    /// `CISharpenLuminance` is what this used every time, and it is the right filter for a
    /// small radius. At a large one it leaves a **seam** down the sky: a visible step in what
    /// the treatment changed, measured at 0.04 of full luminance on a downscaled export and
    /// 0.0009 at full size — which is the tell. The filter is a convolution, and Core Image
    /// renders a big picture in tiles; a kernel wider than the overlap between two tiles sees
    /// different neighbourhoods either side of the line.
    ///
    /// So a large radius is done by hand instead, the way an unsharp mask is defined: the
    /// picture, plus what is left when a blurred copy is taken away from it. `CIGaussianBlur`
    /// is separable and crosses tiles without a mark, and the blur is computed on a reduced
    /// copy — a blur that wide holds nothing a quarter-size copy cannot carry, which is the
    /// same trade `GlowStage` makes.
    static func addingPresence(_ image: CIImage, radius: Float, sharpness: Float, extent: CGRect) -> CIImage {
        guard sharpness > 0 else { return image }
        guard radius > Self.seamlessRadius else {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = image
            sharpen.radius = radius
            sharpen.sharpness = sharpness
            return sharpen.outputImage?.cropped(to: extent) ?? image
        }
        let shrink = CGFloat(Self.seamlessRadius / radius)
        let blurred = image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
            .applyingGaussianBlur(sigma: Double(radius) * Double(shrink) / 2)
            .transformed(by: CGAffineTransform(scaleX: 1 / shrink, y: 1 / shrink))
            .cropped(to: extent)
        // `in + k(in - blur)` written as one matrix over the two: linear dodge would clip, and
        // a difference blend loses the sign. Core Image holds colour premultiplied by alpha,
        // so both sides are opaque and the alpha of the answer is set once, at the end.
        let mix = CIFilter.colorMatrix()
        mix.inputImage = blurred
        mix.rVector = CIVector(x: -CGFloat(sharpness), y: 0, z: 0, w: 0)
        mix.gVector = CIVector(x: 0, y: -CGFloat(sharpness), z: 0, w: 0)
        mix.bVector = CIVector(x: 0, y: 0, z: -CGFloat(sharpness), w: 0)
        mix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let negated = mix.outputImage else { return image }
        let scaled = CIFilter.colorMatrix()
        scaled.inputImage = image
        scaled.rVector = CIVector(x: 1 + CGFloat(sharpness), y: 0, z: 0, w: 0)
        scaled.gVector = CIVector(x: 0, y: 1 + CGFloat(sharpness), z: 0, w: 0)
        scaled.bVector = CIVector(x: 0, y: 0, z: 1 + CGFloat(sharpness), w: 0)
        scaled.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        scaled.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let lifted = scaled.outputImage else { return image }
        let sum = CIFilter.additionCompositing()
        sum.inputImage = lifted
        sum.backgroundImage = negated
        return sum.outputImage?.cropped(to: extent) ?? image
    }

    /// The widest `CISharpenLuminance` is asked for, in pixels. Above it the convolution
    /// starts to cross Core Image's tiles, and a reduced copy carries the blur just as well.
    static let seamlessRadius: Float = 40
}

/// One scale of local contrast: how strong, and over what share of the picture's long edge.
struct LocalContrastScale {
    let amount: Double
    let radiusShare: Double
    let strength: Float
}

/// Presence at three scales, in one pass: what dehaze restores over large areas, clarity at
/// a medium scale (it gives presence to a flat picture without touching its overall tones),
/// and structure at a fine one (it brings out texture: stone, bark, fabric). Negative clarity
/// and structure soften.
public struct LocalContrastStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        guard !image.extent.isInfinite else { return image }
        return image.localContrast([
            LocalContrastScale(amount: max(0, Slider.bipolar(adjustments.dehaze)), radiusShare: 0.06, strength: 0.35),
            LocalContrastScale(amount: Slider.bipolar(adjustments.clarity), radiusShare: 0.02, strength: 0.9),
            LocalContrastScale(amount: Slider.bipolar(adjustments.structure), radiusShare: 0.004, strength: 0.8),
        ])
    }
}

/// Cuts through haze: what veils a picture lifts its blacks and washes its colors out, so
/// blacks are pulled back down and color comes back a little. The contrast haze flattens over
/// large areas is restored by `LocalContrastStage`. Negative values add a veil.
public struct DehazeStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let amount = Slider.bipolar(adjustments.dehaze)
        guard amount != 0, !image.extent.isInfinite else { return image }

        // out = (in - veil) / (1 - veil): removes a uniform veil, or adds one when negative.
        let veil = amount * 0.08
        let scale = 1 / (1 - veil)
        let color = CIFilter.colorControls()
        color.inputImage = image.scalingRGB(by: scale, bias: -veil * scale)
        color.saturation = Float(1 + amount * 0.08)
        return color.outputImage?.cropped(to: image.extent) ?? image
    }
}

/// A soft glow around the light parts of the picture (the "Orton" look): the picture,
/// blurred, screened over itself.
public struct GlowStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let amount = Slider.unipolar(adjustments.glow)
        guard amount > 0, !image.extent.isInfinite else { return image }
        // A wide blur holds no detail: it is computed on a quarter-size copy and scaled back
        // up, at a sixteenth of the pixels.
        let shrink: CGFloat = 0.25
        let blurred = image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
            .applyingGaussianBlur(sigma: Double(image.radius(0.015)) * Double(shrink))
            .transformed(by: CGAffineTransform(scaleX: 1 / shrink, y: 1 / shrink))
            .cropped(to: image.extent)

        // Fading the blurred layer toward black makes the screen blend proportional.

        let screen = CIFilter.screenBlendMode()
        screen.inputImage = blurred.scalingRGB(by: amount * 0.6)
        screen.backgroundImage = image
        return screen.outputImage?.cropped(to: image.extent) ?? image
    }
}

/// Film grain: monochrome noise, the same on every render, whose size follows the picture.
public struct GrainStage: PipelineStage {
    /// Size of a grain, as a share of the long edge.
    static let grainShare = 0.0012

    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let amount = Slider.unipolar(adjustments.grain)
        guard amount > 0, !image.extent.isInfinite, let noise = CIFilter.randomGenerator().outputImage else { return image }

        // The generator is a fixed, infinite pattern: scaled with the picture, a preview and
        // an export show the same grain at the same place.
        let scale = max(1, CGFloat(Self.grainShare * max(image.extent.width, image.extent.height)))
        // The generator's alpha is random too, and a color matrix divides by alpha first:
        // laid over black, the noise becomes opaque and keeps its values.
        let opaque = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).composited(over: CIImage(color: .black))
        let monochrome = CIFilter.colorMatrix()
        monochrome.inputImage = opaque
        // Centered on mid-gray, which a soft light blend leaves untouched; amplitude from the slider.
        let gain = amount * 0.35
        monochrome.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        monochrome.gVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        monochrome.bVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        monochrome.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        monochrome.biasVector = CIVector(x: 0.5 - gain / 2, y: 0.5 - gain / 2, z: 0.5 - gain / 2, w: 1)

        let softLight = CIFilter.softLightBlendMode()
        softLight.inputImage = monochrome.outputImage?.cropped(to: image.extent)
        softLight.backgroundImage = image
        return softLight.outputImage?.cropped(to: image.extent) ?? image
    }
}
