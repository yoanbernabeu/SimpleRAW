import Foundation

/// The hue families of the HSL panel, in hue-circle order.
public enum ColorBandName: String, CaseIterable, CodingKey, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    /// Center of the band on the hue circle, in degrees.
    var centerHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 300
        }
    }
}

/// Settings of one band, each from -100 to +100.
public struct ColorBand: Codable, Equatable, Sendable {
    public var hue: Double = 0
    public var saturation: Double = 0
    public var luminance: Double = 0

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public init(from decoder: Decoder) throws {
        let neutral = ColorBand()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hue = try container.decodeIfPresent(Double.self, forKey: .hue) ?? neutral.hue
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? neutral.saturation
        luminance = try container.decodeIfPresent(Double.self, forKey: .luminance) ?? neutral.luminance
    }
}

/// Per-band color settings. Only edited bands are stored, so that a band put back to neutral
/// leaves no trace in the document.
public struct HSLAdjustments: Equatable, Sendable {
    private var bands: [ColorBandName: ColorBand] = [:]

    public init() {}

    public subscript(band: ColorBandName) -> ColorBand {
        get { bands[band] ?? ColorBand() }
        set { bands[band] = newValue == ColorBand() ? nil : newValue }
    }

    public var isNeutral: Bool { bands.isEmpty }
}

extension HSLAdjustments: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ColorBandName.self)
        for band in container.allKeys {
            self[band] = try container.decode(ColorBand.self, forKey: band)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ColorBandName.self)
        for band in ColorBandName.allCases where bands[band] != nil {
            try container.encode(self[band], forKey: band)
        }
    }
}

/// The HSL panel as a pure function on display-referred (sRGB-encoded) RGB.
struct HSLTransform: Sendable {
    /// Hue rotation for a slider at full scale, in degrees: up to the neighbouring band.
    static let maximumHueShift = 30.0
    /// Lightness change for a slider at full scale, on a fully saturated color.
    static let maximumLuminanceShift = 0.3

    /// Band order and centers, laid out once: `allCases` allocates on every access.
    private static let bands = ColorBandName.allCases
    private static let centers = bands.map(\.centerHue)

    /// Per band, in `bands` order, already scaled to engine units.
    private let hueShifts: [Double]
    private let saturationGains: [Double]
    private let lightnessShifts: [Double]

    init(_ settings: HSLAdjustments) {
        let values = Self.bands.map { settings[$0] }
        hueShifts = values.map { Slider.bipolar($0.hue) * Self.maximumHueShift }
        saturationGains = values.map { Slider.bipolar($0.saturation) }
        lightnessShifts = values.map { Slider.bipolar($0.luminance) * Self.maximumLuminanceShift }
    }

    func apply(to rgb: SIMD3<Float>) -> SIMD3<Float> {
        var (hue, saturation, lightness) = Self.hsl(from: rgb)
        // Grays have no hue to speak of: they belong to no band.
        guard saturation > 0 else { return rgb }

        let blend = Self.bandBlend(forHue: hue)
        let (a, b, t) = (blend.from, blend.to, blend.handOver)
        let hueShift = hueShifts[a] * (1 - t) + hueShifts[b] * t
        let saturationGain = saturationGains[a] * (1 - t) + saturationGains[b] * t
        let lightnessShift = lightnessShifts[a] * (1 - t) + lightnessShifts[b] * t
        hue = (hue + hueShift).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        // Scaled by saturation so that the effect fades smoothly toward the neutrals.
        lightness = min(max(lightness + lightnessShift * saturation, 0), 1)
        saturation = min(max(saturation * (1 + saturationGain), 0), 1)
        return Self.rgb(hue: hue, saturation: saturation, lightness: lightness)
    }

    /// How much each band owns a hue. A hue between two band centers is shared by both, with
    /// a smooth hand-over; weights always add up to 1. Bands owning nothing are left out.
    static func bandWeights(forHue hue: Double) -> [ColorBandName: Double] {
        let blend = bandBlend(forHue: hue)
        return [bands[blend.from]: 1 - blend.handOver, bands[blend.to]: blend.handOver].filter { $0.value > 0 }
    }

    /// The two bands (as indices into `bands`) a hue sits between, and how far it has been
    /// handed over to the second. Allocation-free: it runs once per node of the lookup table.
    static func bandBlend(forHue hue: Double) -> (from: Int, to: Int, handOver: Double) {
        for index in centers.indices {
            let next = (index + 1) % centers.count
            let start = centers[index]
            let end = centers[next] > start ? centers[next] : centers[next] + 360
            guard hue >= start, hue < end else { continue }
            let t = (hue - start) / (end - start)
            return (index, next, t * t * (3 - 2 * t))
        }
        return (0, 0, 0)
    }

    // MARK: - Color space conversions

    static func hsl(from rgb: SIMD3<Float>) -> (hue: Double, saturation: Double, lightness: Double) {
        let (r, g, b) = (Double(rgb.x), Double(rgb.y), Double(rgb.z))
        let (high, low) = (max(r, g, b), min(r, g, b))
        let lightness = (high + low) / 2
        let chroma = high - low
        guard chroma > 1e-9 else { return (0, 0, lightness) }

        let saturation = chroma / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case r: hue = ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / chroma + 2
        default: hue = (r - g) / chroma + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(saturation, 1), lightness)
    }

    static func rgb(hue: Double, saturation: Double, lightness: Double) -> SIMD3<Float> {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(sector) % 6 {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let offset = lightness - chroma / 2
        return SIMD3(Float(r + offset), Float(g + offset), Float(b + offset))
    }
}
