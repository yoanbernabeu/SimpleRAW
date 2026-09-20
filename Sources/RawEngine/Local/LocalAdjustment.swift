import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// What a local adjustment changes, inside its mask. Exposure is in EV, the rest goes from
/// -100 to +100.
public struct LocalSettings: Codable, Equatable, Sendable {
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var saturation: Double = 0
    /// Presence at a medium scale, and haze cut through or added: a gaze gets a little of the
    /// first, a sky some of the second.
    public var clarity: Double = 0
    public var dehaze: Double = 0
    /// Positive warms, negative cools.
    public var temperature: Double = 0
    /// Positive toward magenta, negative toward green.
    public var tint: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let neutral = LocalSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? neutral.exposure
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? neutral.contrast
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? neutral.highlights
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? neutral.shadows
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? neutral.saturation
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? neutral.clarity
        dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? neutral.dehaze
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? neutral.temperature
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? neutral.tint
    }

    public var isNeutral: Bool { self == LocalSettings() }

    /// Every setting but exposure, which is in EV: sliders from -100 to +100.
    static let sliders: [WritableKeyPath<LocalSettings, Double> & Sendable] = [
        \.contrast, \.highlights, \.shadows, \.saturation, \.clarity, \.dehaze, \.temperature, \.tint,
    ]

    /// Shift of the white point for a slider at full scale, in kelvins and in tint units.
    static let maximumTemperatureShift = 3000.0
    static let maximumTintShift = 100.0

    /// The whole image with these settings applied; the mask then decides where it shows.
    /// Tone and saturation reuse the global stages, so that a local slider feels the same
    /// as its global counterpart.
    func apply(to image: CIImage) -> CIImage {
        var output = image
        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(exposure)
            output = filter.outputImage ?? output
        }
        if temperature != 0 || tint != 0 {
            // Declaring the light bluer than it was makes the filter warm the picture up.
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(
                x: 6500 + Slider.bipolar(temperature) * Self.maximumTemperatureShift,
                y: Slider.bipolar(tint) * Self.maximumTintShift
            )
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            output = filter.outputImage ?? output
        }
        var global = Adjustments()
        global.contrast = contrast
        global.highlights = highlights
        global.shadows = shadows
        global.saturation = saturation
        global.clarity = clarity
        global.dehaze = dehaze
        return Self.sharedStages.reduce(output) { $1.apply(global, to: $0) }
    }

    /// In the order of the global pipeline. Each one returns its input untouched when its
    /// sliders are neutral: a layer without clarity pays for no blur.
    private static let sharedStages: [any PipelineStage] = [
        HighlightsShadowsStage(), ToneCurveStage(), DehazeStage(), LocalContrastStage(), SaturationStage(),
    ]
}

/// A set of changes limited to a part of the picture. It is a layer: it can be hidden,
/// faded, renamed, moved in the stack or removed without touching the layers around it.
public struct LocalAdjustment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// `nil` = named after its mask ("Brush 2").
    public var name: String?
    public var isEnabled = true
    /// From 0 to 100: how much of the layer shows.
    public var opacity: Double = 100
    public var mask: Mask
    /// The tones the layer is limited to, inside its mask. `nil` = all of them; a range from
    /// black to white is stored as `nil`.
    public var luminanceRange: LuminanceRange? {
        didSet { if luminanceRange?.isWhole == true { luminanceRange = nil } }
    }
    public var settings: LocalSettings

    public init(id: UUID = UUID(), mask: Mask, settings: LocalSettings = LocalSettings()) {
        self.id = id
        self.mask = mask
        self.settings = settings
    }

    /// Documents written before layers existed hold `id`, `mask` and `settings` only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 100
        mask = try container.decode(Mask.self, forKey: .mask)
        let range = try container.decodeIfPresent(LuminanceRange.self, forKey: .luminanceRange)
        luminanceRange = range?.isWhole == true ? nil : range
        settings = try container.decodeIfPresent(LocalSettings.self, forKey: .settings) ?? LocalSettings()
    }

    /// Whether rendering the layer can change a single pixel.
    var hasEffect: Bool {
        isEnabled && opacity > 0 && !settings.isNeutral
    }
}

// MARK: - The stack

extension Array where Element == LocalAdjustment {
    /// Moves a layer up (positive) or down the stack, stopping at its ends.
    public mutating func moveLayer(withID id: UUID, by offset: Int) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        let destination = Swift.min(Swift.max(index + offset, 0), count - 1)
        insert(remove(at: index), at: destination)
    }

    /// Copies a layer right above itself. The copy is a layer of its own.
    @discardableResult
    public mutating func duplicateLayer(withID id: UUID) -> LocalAdjustment? {
        guard let index = firstIndex(where: { $0.id == id }) else { return nil }
        var copy = self[index]
        copy.id = UUID()
        copy.name = displayNames[index] + " copy"
        insert(copy, at: index + 1)
        return copy
    }

    /// What to call each layer: its own name, or its kind of mask and its rank among them.
    public var displayNames: [String] {
        var ranks: [MaskKind: Int] = [:]
        return map { layer in
            ranks[layer.mask.kind, default: 0] += 1
            return layer.name ?? "\(layer.mask.kind.rawValue) \(ranks[layer.mask.kind, default: 1])"
        }
    }
}
