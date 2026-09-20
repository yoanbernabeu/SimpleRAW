import Foundation
import RawEngine

/// What a slider needs to know about the open file: some neutral positions are not 0 but
/// whatever the camera or the decoder chose.
public struct SliderContext: Sendable {
    public let asShotWhiteBalance: WhiteBalance
    public let decoderDefaults: RawInfo.DecoderDefaults

    public init(asShotWhiteBalance: WhiteBalance, decoderDefaults: RawInfo.DecoderDefaults) {
        self.asShotWhiteBalance = asShotWhiteBalance
        self.decoderDefaults = decoderDefaults
    }

    public init(_ info: RawInfo) {
        self.init(asShotWhiteBalance: info.asShotWhiteBalance, decoderDefaults: info.decoderDefaults)
    }
}

/// Declarative description of one slider of the inspector. The inspector is generated from
/// `SliderSpec.all`: adding a slider is adding an entry here, not writing a view.
public struct SliderSpec: Identifiable, Sendable {
    public enum Section: String, CaseIterable, Sendable {
        /// The one-gesture tools, at the top of the inspector.
        case essentials = "Essentials"
        case light = "Light"
        case color = "Color"
        case effects = "Effects"
        case detail = "Detail"
        case optics = "Optics"
        /// Shown by the HSL panel, one band at a time, rather than listed with the others.
        case hsl = "HSL"
        /// Shown under the black and white switch, once it is on.
        case blackAndWhite = "Black & White"
        /// Shown by the color grading panel, next to its wheels.
        case grading = "Color grading"
        /// Shown by the crop tool.
        case geometry = "Geometry"
        /// Shown by the local tool, for the selected mask.
        case local = "Local"

        /// Sections the inspector generates as a plain list of sliders.
        public static let listed: [Section] = [.essentials, .light, .color, .effects, .detail, .optics]
    }

    /// What the two ends of a track stand for, when it is more than "less" and "more".
    public enum Track: Sendable {
        case temperature, tint
    }

    public let title: String
    public let section: Section
    public let range: ClosedRange<Double>
    public let step: Double
    public let fractionDigits: Int
    public var track: Track?
    public let neutral: @Sendable (SliderContext) -> Double
    public let value: @Sendable (Adjustments, SliderContext) -> Double
    public let setValue: @Sendable (inout Adjustments, Double, SliderContext) -> Void

    public var id: String { title }

    public func reset(_ adjustments: inout Adjustments, _ context: SliderContext) {
        setValue(&adjustments, neutral(context), context)
    }
}

// MARK: - Builders

extension SliderSpec {
    /// A slider bound to a plain field, neutral at 0.
    static func centered(
        _ title: String,
        _ section: Section,
        _ keyPath: WritableKeyPath<Adjustments, Double> & Sendable,
        range: ClosedRange<Double> = -100...100,
        step: Double = 1,
        fractionDigits: Int = 0
    ) -> SliderSpec {
        SliderSpec(
            title: title, section: section, range: range, step: step, fractionDigits: fractionDigits,
            neutral: { _ in 0 },
            value: { adjustments, _ in adjustments[keyPath: keyPath] },
            setValue: { adjustments, value, _ in adjustments[keyPath: keyPath] = value }
        )
    }

    /// A slider bound to an optional field, whose neutral position is the decoder's choice.
    /// Sitting on that position stores `nil`, so the document stays neutral.
    static func decoderAmount(
        _ title: String,
        _ keyPath: WritableKeyPath<Adjustments, Double?> & Sendable,
        default decoderDefault: KeyPath<RawInfo.DecoderDefaults, Double> & Sendable
    ) -> SliderSpec {
        SliderSpec(
            title: title, section: .detail, range: 0...100, step: 1, fractionDigits: 0,
            neutral: { $0.decoderDefaults[keyPath: decoderDefault] },
            value: { adjustments, context in
                adjustments[keyPath: keyPath] ?? context.decoderDefaults[keyPath: decoderDefault]
            },
            setValue: { adjustments, value, context in
                let isDefault = value == context.decoderDefaults[keyPath: decoderDefault]
                adjustments[keyPath: keyPath] = isDefault ? nil : value
            }
        )
    }
}

// MARK: - The inspector

extension SliderSpec {
    public static let all: [SliderSpec] = [
        .centered("Enhance", .essentials, \.enhance, range: 0...100),

        .centered("Exposure", .light, \.exposure, range: -5...5, step: 0.05, fractionDigits: 2),
        .centered("Contrast", .light, \.contrast),
        .centered("Highlights", .light, \.highlights),
        .centered("Shadows", .light, \.shadows),
        .centered("Whites", .light, \.whites),
        .centered("Blacks", .light, \.blacks),

        SliderSpec(
            title: "Temperature", section: .color, range: 2000...12000, step: 50, fractionDigits: 0, track: .temperature,
            neutral: { $0.asShotWhiteBalance.temperature },
            value: { $0.whiteBalance(orAsShot: $1.asShotWhiteBalance).temperature },
            setValue: { $0.setTemperature($1, asShot: $2.asShotWhiteBalance) }
        ),
        SliderSpec(
            title: "Tint", section: .color, range: -150...150, step: 1, fractionDigits: 0, track: .tint,
            neutral: { $0.asShotWhiteBalance.tint },
            value: { $0.whiteBalance(orAsShot: $1.asShotWhiteBalance).tint },
            setValue: { $0.setTint($1, asShot: $2.asShotWhiteBalance) }
        ),
        .centered("Vibrance", .color, \.vibrance),
        .centered("Saturation", .color, \.saturation),

        .centered("Clarity", .effects, \.clarity),
        .centered("Structure", .effects, \.structure),
        .centered("Dehaze", .effects, \.dehaze),
        .centered("Glow", .effects, \.glow, range: 0...100),
        .centered("Grain", .effects, \.grain, range: 0...100),

        .decoderAmount("Sharpness", \.sharpness, default: \.sharpness),
        .decoderAmount("Luminance noise", \.luminanceNoiseReduction, default: \.luminanceNoiseReduction),
        .decoderAmount("Color noise", \.colorNoiseReduction, default: \.colorNoiseReduction),

        .centered("Vignetting", .optics, \.vignetting),
        // Lateral chromatic aberration, by hand: the decoder corrects none on this camera.
        .centered("Red / cyan fringe", .optics, \.aberration.redCyan),
        .centered("Blue / yellow fringe", .optics, \.aberration.blueYellow),
        .centered("Defringe", .optics, \.purpleFringe.amount, range: 0...100),
        // Only where the build had a Metal compiler: see `MetalKernels`.
        .centered("Distortion", .optics, \.distortion),
        // Keystone correction sits with what else the lens and the viewpoint did to the
        // picture, rather than with the crop: it is a correction, not a framing choice —
        // even though, like straightening, it costs a little of the frame.
        .centered("Vertical tilt", .optics, \.geometry.perspective.vertical),
        .centered("Horizontal tilt", .optics, \.geometry.perspective.horizontal),

        .centered("Balance", .grading, \.grading.balance),

        .centered("Reds", .blackAndWhite, \.blackAndWhite.red),
        // The channel of skin tones: what a portrait in black and white is set with.
        .centered("Oranges", .blackAndWhite, \.blackAndWhite.orange),
        .centered("Yellows", .blackAndWhite, \.blackAndWhite.yellow),
        .centered("Greens", .blackAndWhite, \.blackAndWhite.green),
        .centered("Cyans", .blackAndWhite, \.blackAndWhite.cyan),
        .centered("Blues", .blackAndWhite, \.blackAndWhite.blue),
        .centered("Magentas", .blackAndWhite, \.blackAndWhite.magenta),

        .centered("Straighten", .geometry, \.geometry.straighten, range: -45...45, step: 0.1, fractionDigits: 1),
    ]

    /// Hue, saturation and luminance of one band, in that order.
    public static func hsl(band: ColorBandName) -> [SliderSpec] {
        [
            .centered("Hue", .hsl, \.hsl[band].hue),
            .centered("Saturation", .hsl, \.hsl[band].saturation),
            .centered("Luminance", .hsl, \.hsl[band].luminance),
        ]
    }

    public static func grading(range: TonalRange) -> [SliderSpec] {
        [.centered("\(range.rawValue.capitalized) luminance", .grading, \.grading[range].luminance)]
    }

    /// The settings of one local adjustment. Its first slider is exposure.
    public static func local(id: UUID) -> [SliderSpec] {
        [
            .centered("Exposure", .local, \.[local: id].exposure, range: -4...4, step: 0.05, fractionDigits: 2),
            .centered("Contrast", .local, \.[local: id].contrast),
            .centered("Highlights", .local, \.[local: id].highlights),
            .centered("Shadows", .local, \.[local: id].shadows),
            .centered("Saturation", .local, \.[local: id].saturation),
            .centered("Clarity", .local, \.[local: id].clarity),
            // Haze cut through on one part of the frame: the far hills, not the foreground.
            // It is the dearest setting a layer can hold, so it pays for nothing at 0.
            .centered("Dehaze", .local, \.[local: id].dehaze),
            .centered("Temperature", .local, \.[local: id].temperature),
            .centered("Tint", .local, \.[local: id].tint),
        ]
    }

    public static func all(in section: Section) -> [SliderSpec] {
        all.filter { $0.section == section && $0.isAvailable }
    }

    /// A slider that does nothing is worse than no slider: the one setting that needs a Metal
    /// kernel is not offered by a build that has none.
    var isAvailable: Bool {
        title != "Distortion" || MetalKernels.isAvailable
    }
}
