import Foundation

/// Taking the violet out of a fringe, and leaving every other violet alone.
///
/// A hard edge against a bright sky — a branch, a railing, a roofline — comes back from most
/// lenses with a coloured halo along it, violet on one side and sometimes green on the other.
/// It is not chromatic aberration in the sense the two fringe sliders correct, which is the
/// three channels being drawn at slightly different sizes and is fixed by scaling them back;
/// this is light of one colour smeared by the glass itself, and no amount of scaling moves it.
///
/// What it is, though, is a colour: a narrow band between blue and magenta that nothing in a
/// photograph naturally occupies at that saturation. So it is taken out by washing that band
/// to grey — and only where the picture has an edge, which is the stage's part of the work.
/// The brightness is kept: a dark line where a bright one was is a worse fault than the halo.
///
/// The band is narrow on purpose. The colour mixer has bands either side of it and none on it,
/// which is exactly why a photographer cannot do this with the mixer: reaching the fringe there
/// means taking the colour out of the sky with it.
public struct PurpleFringe: Codable, Equatable, Sendable {
    /// How much of the colour is taken out where an edge is found, 0 to 100.
    public var amount: Double = 0

    public init(amount: Double = 0) {
        self.amount = amount
    }

    public var isNeutral: Bool { amount <= 0 }

    /// Violet through magenta, in degrees of hue. Blue proper ends around 250 and red begins
    /// past 330; between them is a band a scene rarely fills and a lens often does.
    ///
    /// The middle of it is taken whole, and only the shoulders are eased off — a fringe sits
    /// squarely in the band, and a taper from the very edges would leave most of one behind.
    /// The shoulders are there so that a gradient running across the band has no step in it,
    /// which is the fault this kind of correction is usually caught by.
    public static let band: ClosedRange<Double> = 255...320
    public static let core: ClosedRange<Double> = 265...305
    /// Below this there is no colour to speak of, and no hue worth asking for.
    public static let leastSaturation: Float = 0.12

    /// How much of the band a hue is in: 1 across the middle, easing to 0 at either edge.
    public static func share(ofHue hue: Double) -> Double {
        guard band.contains(hue) else { return 0 }
        if core.contains(hue) { return 1 }
        return hue < core.lowerBound
            ? (hue - band.lowerBound) / (core.lowerBound - band.lowerBound)
            : (band.upperBound - hue) / (band.upperBound - core.upperBound)
    }

    public static func luminance(_ colour: SIMD3<Float>) -> Float {
        0.2126 * colour.x + 0.7152 * colour.y + 0.0722 * colour.z
    }

    /// The colour as it is left. Anything outside the band comes back untouched, which is what
    /// lets the stage hand the whole picture to one lookup table.
    public func corrected(_ colour: SIMD3<Float>) -> SIMD3<Float> {
        guard !isNeutral else { return colour }
        let (high, low) = (colour.max(), colour.min())
        let chroma = high - low
        guard chroma > Self.leastSaturation, high > 0 else { return colour }
        let share = Self.share(ofHue: Self.hue(of: colour, high: high, chroma: chroma))
        guard share > 0 else { return colour }
        // Washed towards its own brightness rather than towards grey: the halo goes, the line
        // stays where it was.
        let strength = Float(min(1, max(0, amount / 100)) * share)
        let grey = SIMD3<Float>(repeating: Self.luminance(colour))
        return colour + (grey - colour) * strength
    }

    /// Degrees, the usual way round: red at 0, green at 120, blue at 240.
    private static func hue(of colour: SIMD3<Float>, high: Float, chroma: Float) -> Double {
        let raw: Float
        if high == colour.x {
            raw = (colour.y - colour.z) / chroma
        } else if high == colour.y {
            raw = 2 + (colour.z - colour.x) / chroma
        } else {
            raw = 4 + (colour.x - colour.y) / chroma
        }
        let degrees = Double(raw) * 60
        return degrees < 0 ? degrees + 360 : degrees
    }
}
