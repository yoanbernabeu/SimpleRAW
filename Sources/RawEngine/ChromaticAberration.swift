import Foundation

/// Manual correction of **lateral** chromatic aberration: the coloured fringes a lens leaves
/// along contrasty edges near the corners, red on one side and cyan on the other, because the
/// lens does not focus every wavelength at quite the same size.
///
/// The correction is one number per pair: the red channel is scaled against the green, and the
/// blue channel against it too. That is what lateral aberration is, to the order that matters —
/// a difference of magnification — and it is the one part of a lens profile that stock filters
/// can express exactly, because a uniform radial scale is an affine transform.
///
/// Barrel and pincushion distortion are not: they need `r' = r(1 + k·r²)`, a warp kernel, and
/// the project builds without Xcode's Metal compiler on purpose. See `docs/TODO.md`.
public struct ChromaticAberration: Codable, Equatable, Sendable {
    /// -100…100. Positive magnifies the red channel, which carries red detail **outwards**,
    /// away from the middle of the frame — so it answers a picture whose fringes are red on
    /// the inner side of an edge and cyan on the outer.
    public var redCyan: Double = 0
    /// -100…100. Positive magnifies the blue channel, the same way.
    public var blueYellow: Double = 0

    /// What a slider at full scale asks for, as a fraction of the frame. Half a percent is
    /// already more than any lens of this kind leaves: on a 6000 px frame it moves a corner
    /// by fifteen pixels, and the fringes being chased are worth a few.
    public static let maximumScale = 0.005

    public init(redCyan: Double = 0, blueYellow: Double = 0) {
        self.redCyan = redCyan
        self.blueYellow = blueYellow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        redCyan = try container.decodeIfPresent(Double.self, forKey: .redCyan) ?? 0
        blueYellow = try container.decodeIfPresent(Double.self, forKey: .blueYellow) ?? 0
    }

    public var isNeutral: Bool { self == ChromaticAberration() }

    /// How much each channel is scaled about the middle of the frame. Green never moves: it is
    /// what the other two are brought back to.
    public var scales: (red: Double, blue: Double) {
        (red: 1 + Self.maximumScale * Slider.bipolar(redCyan),
         blue: 1 + Self.maximumScale * Slider.bipolar(blueYellow))
    }
}
