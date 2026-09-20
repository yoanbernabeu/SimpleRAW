import Foundation

/// Black and white, with a say on how bright each color comes out: what a colored filter in
/// front of the lens does on film. Channel values go from -100 to +100.
public struct BlackAndWhite: Codable, Equatable, Sendable {
    public var isEnabled = false
    public var red: Double = 0
    /// The channel of skin tones. It adds to what red and yellow give the hues between them,
    /// so that a picture edited before it existed comes out as it did.
    public var orange: Double = 0
    public var yellow: Double = 0
    public var green: Double = 0
    public var cyan: Double = 0
    public var blue: Double = 0
    public var magenta: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let neutral = BlackAndWhite()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? neutral.isEnabled
        red = try c.decodeIfPresent(Double.self, forKey: .red) ?? neutral.red
        orange = try c.decodeIfPresent(Double.self, forKey: .orange) ?? neutral.orange
        yellow = try c.decodeIfPresent(Double.self, forKey: .yellow) ?? neutral.yellow
        green = try c.decodeIfPresent(Double.self, forKey: .green) ?? neutral.green
        cyan = try c.decodeIfPresent(Double.self, forKey: .cyan) ?? neutral.cyan
        blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? neutral.blue
        magenta = try c.decodeIfPresent(Double.self, forKey: .magenta) ?? neutral.magenta
    }

    /// Every slider of the mixer.
    static let channels: [WritableKeyPath<BlackAndWhite, Double> & Sendable] = [\.red, \.orange, \.yellow, \.green, \.cyan, \.blue, \.magenta]

    /// In hue-circle order, every 60°, starting at red. Orange is apart: see `orange`.
    var mix: [Double] { [red, yellow, green, cyan, blue, magenta] }
}

/// Black and white as a pure function on display-referred RGB.
struct BlackAndWhiteTransform: Sendable {
    /// Brightness change for a channel at full scale, on a fully saturated color.
    static let maximumShift = 0.6

    /// Orange peaks here and fades out toward red and yellow, its neighbours.
    static let orangeHue = 30.0

    private let isEnabled: Bool
    private let mix: [Double]
    private let orange: Double

    init(_ settings: BlackAndWhite) {
        isEnabled = settings.isEnabled
        mix = settings.mix.map { Slider.bipolar($0) * Self.maximumShift }
        orange = Slider.bipolar(settings.orange) * Self.maximumShift
    }

    func apply(to rgb: SIMD3<Float>) -> SIMD3<Float> {
        guard isEnabled else { return rgb }
        let luma = Double(ColorGradingTransform.luma(rgb))
        let (hue, saturation, _) = HSLTransform.hsl(from: rgb)
        // Each hue sits between two channels, 60° apart, and follows both in proportion.
        let position = hue / 60
        let lower = Int(position) % 6
        let share = position - Double(Int(position))
        let nearOrange = max(0, 1 - abs(hue - Self.orangeHue) / Self.orangeHue)
        let shift = mix[lower] * (1 - share) + mix[(lower + 1) % 6] * share + orange * nearOrange
        // Scaled by saturation: a gray has no color for the mix to act on.
        let gray = Float(min(max(luma * (1 + shift * saturation), 0), 1))
        return SIMD3(repeating: gray)
    }
}
