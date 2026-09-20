import Foundation
import simd

public enum TonalRange: String, CaseIterable, Sendable {
    case shadows, midtones, highlights
}

/// One wheel of the color grading panel: a tint (hue in degrees, saturation from 0 to 100)
/// and a luminance offset (-100 to +100).
public struct ColorWheel: Codable, Equatable, Sendable {
    public var hue: Double = 0
    public var saturation: Double = 0
    public var luminance: Double = 0

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public init(from decoder: Decoder) throws {
        let neutral = ColorWheel()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hue = try container.decodeIfPresent(Double.self, forKey: .hue) ?? neutral.hue
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? neutral.saturation
        luminance = try container.decodeIfPresent(Double.self, forKey: .luminance) ?? neutral.luminance
    }

    /// A hue without saturation tints nothing: dropping it keeps neutral documents neutral.
    var normalized: ColorWheel {
        saturation == 0 ? ColorWheel(hue: 0, saturation: 0, luminance: luminance) : self
    }
}

public struct ColorGrading: Codable, Equatable, Sendable {
    private var shadows = ColorWheel()
    private var midtones = ColorWheel()
    private var highlights = ColorWheel()
    /// From -100 to +100: positive hands more of the tonal scale over to the highlights.
    public var balance: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let neutral = ColorGrading()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try container.decodeIfPresent(ColorWheel.self, forKey: .shadows)?.normalized ?? neutral.shadows
        midtones = try container.decodeIfPresent(ColorWheel.self, forKey: .midtones)?.normalized ?? neutral.midtones
        highlights = try container.decodeIfPresent(ColorWheel.self, forKey: .highlights)?.normalized ?? neutral.highlights
        balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? neutral.balance
    }

    public subscript(range: TonalRange) -> ColorWheel {
        get {
            switch range {
            case .shadows: shadows
            case .midtones: midtones
            case .highlights: highlights
            }
        }
        set {
            switch range {
            case .shadows: shadows = newValue.normalized
            case .midtones: midtones = newValue.normalized
            case .highlights: highlights = newValue.normalized
            }
        }
    }

    /// Balance alone does nothing: it only matters once a wheel is off-center.
    public var isNeutral: Bool {
        TonalRange.allCases.allSatisfy { self[$0] == ColorWheel() }
    }
}

/// Color grading as a pure function on display-referred (sRGB-encoded) RGB.
struct ColorGradingTransform: Sendable {
    /// Color offset for a fully saturated wheel, fully weighted.
    static let tintStrength: Float = 0.35
    static let luminanceStrength: Float = 0.25

    private let isNeutral: Bool
    private let balance: Double
    /// Per range (shadows, midtones, highlights): what to add to a fully weighted pixel.
    private let offsets: [SIMD3<Float>]

    init(_ grading: ColorGrading) {
        isNeutral = grading.isNeutral
        balance = grading.balance
        offsets = TonalRange.allCases.map { range in
            let wheel = grading[range]
            let pureHue = HSLTransform.rgb(hue: wheel.hue, saturation: 1, lightness: 0.5)
            // Removing its luma makes the tint a pure color shift: brightness stays put.
            let tint = (pureHue - Self.luma(pureHue)) * Float(Slider.unipolar(wheel.saturation)) * Self.tintStrength
            return tint + Float(Slider.bipolar(wheel.luminance)) * Self.luminanceStrength
        }
    }

    func apply(to rgb: SIMD3<Float>) -> SIMD3<Float> {
        guard !isNeutral else { return rgb }
        let weights = Self.rangeWeights(forLuma: Double(Self.luma(rgb)), balance: balance)
        let graded = rgb
            + offsets[0] * Float(weights.shadows)
            + offsets[1] * Float(weights.midtones)
            + offsets[2] * Float(weights.highlights)
        return simd_clamp(graded, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// How the tonal scale is shared: shadows own black, highlights own white, midtones the
    /// middle, with smooth overlaps. The three always add up to 1.
    static func rangeWeights(forLuma luma: Double, balance: Double) -> (shadows: Double, midtones: Double, highlights: Double) {
        // Positive balance lifts the level before splitting, so highlights claim more of it.
        let level = pow(min(max(luma, 0), 1), pow(2, -Slider.bipolar(balance)))
        let shadows = (1 - level) * (1 - level)
        let highlights = level * level
        return (shadows, 2 * level * (1 - level), highlights)
    }

    static func luma(_ rgb: SIMD3<Float>) -> Float {
        Rec709.luma(rgb)
    }
}
