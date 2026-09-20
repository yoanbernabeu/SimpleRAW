import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The tones a local adjustment is limited to, on display levels (0 = black, 1 = white): a
/// graduated filter on the sky that spares the steeple standing in it. A pure function; the
/// mask of the layer is multiplied by it.
public struct LuminanceRange: Codable, Equatable, Sendable {
    public var lower: Double = 0
    public var upper: Double = 1
    /// Width of the fade around each bound, on display levels: what keeps the limit from
    /// drawing an edge of its own.
    public var softness: Double = 0.1

    public init(lower: Double = 0, upper: Double = 1, softness: Double = 0.1) {
        self.lower = lower
        self.upper = upper
        self.softness = softness
    }

    public init(from decoder: Decoder) throws {
        let neutral = LuminanceRange()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lower = try container.decodeIfPresent(Double.self, forKey: .lower) ?? neutral.lower
        upper = try container.decodeIfPresent(Double.self, forKey: .upper) ?? neutral.upper
        softness = try container.decodeIfPresent(Double.self, forKey: .softness) ?? neutral.softness
    }

    /// From black to white: no limit at all, whatever the softness.
    public var isWhole: Bool { lower <= 0 && upper >= 1 }

    /// How much of the layer shows on a tone: 1 inside the range, 0 outside, a smooth step
    /// centered on each bound. A bound at the end of the scale does not fade: black is in a
    /// range that starts at black.
    public func value(at level: Double) -> Double {
        let rising = lower <= 0 ? 1 : Self.smoothstep(level, around: lower, width: softness)
        let falling = upper >= 1 ? 1 : 1 - Self.smoothstep(level, around: upper, width: softness)
        return rising * falling
    }

    private static func smoothstep(_ level: Double, around center: Double, width: Double) -> Double {
        guard width > 0 else { return level >= center ? 1 : 0 }
        let t = min(max((level - (center - width / 2)) / width, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Crossed bounds are put back in order, and what is not a number goes back to neutral:
    /// the one rule, applied both where a document is read and where a slider writes.
    public func sanitized() -> LuminanceRange {
        let lower = self.lower.bounded(to: AdjustmentLimits.unit, else: 0)
        let upper = self.upper.bounded(to: AdjustmentLimits.unit, else: 1)
        return LuminanceRange(lower: min(lower, upper), upper: max(lower, upper), softness: softness.bounded(to: AdjustmentLimits.unit, else: LuminanceRange().softness))
    }
}

extension LuminanceRange {
    static let tableSize = 256
    private static let cache = RecentValuesCache<LuminanceRange, Data>()

    /// White where the tones of `image` are in the range, black where they are not. The
    /// function above, baked into a table the GPU looks luminance up in.
    func mask(for image: CIImage) -> CIImage? {
        // Display levels, as the range is expressed; what is beyond display white is white.
        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = image
        let luminance = CIFilter.colorMatrix()
        luminance.inputImage = encode.outputImage
        (luminance.rVector, luminance.gVector, luminance.bVector) = (Rec709.vector, Rec709.vector, Rec709.vector)

        // A RAW file has highlights beyond display white, and shadows below black: they are
        // highlights and shadows, not tones the table has no entry for.
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = luminance.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

        let lookup = CIFilter.colorCurves()
        lookup.inputImage = clamp.outputImage
        lookup.curvesData = Self.cache.value(for: self) {
            let levels = (0..<Self.tableSize).map { Float(value(at: Double($0) / Double(Self.tableSize - 1))) }
            return levels.flatMap { [$0, $0, $0] }.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        lookup.curvesDomain = CIVector(x: 0, y: 1)
        // Levels in, mask values out, both as they are: no color space to convert through.
        lookup.colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        guard let tones = lookup.outputImage, !image.extent.isInfinite else { return lookup.outputImage }

        // The pixels of an edge are a mix of what lies on each side: between a bright sky and
        // a dark lamp post they are mid-tones, out of a range of highlights. Left as they were
        // next to a sky made darker, they drew a bright line around everything standing in
        // it. The mask is grown by about a pixel of a screen-sized picture, so that an edge
        // goes with the side the range picks.
        let grow = CIFilter.morphologyMaximum()
        grow.inputImage = tones.clampedToExtent()
        grow.radius = Float(Self.edgeShare * max(image.extent.width, image.extent.height))
        return grow.outputImage?.cropped(to: image.extent)
    }

    /// How far the mask grows over edges, as a share of the long edge.
    static let edgeShare = 0.0008
}
