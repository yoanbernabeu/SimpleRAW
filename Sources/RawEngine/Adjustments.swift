import Foundation

/// Development settings of a photo. A versioned JSON document: this is what the catalog
/// will store, and a preset is merely a subset of it.
///
/// Unless stated otherwise, sliders range from -100 to +100 and are neutral at 0.
public struct Adjustments: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = Adjustments.currentVersion

    /// In EV, applied to the linear sensor data.
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0

    public var curves = Curves()
    public var hsl = HSLAdjustments()
    public var blackAndWhite = BlackAndWhite()
    public var grading = ColorGrading()
    public var geometry = Geometry()
    /// Applied in order; each one is limited to its mask.
    public var locals: [LocalAdjustment] = []
    public var spots: [Spot] = []

    /// `nil` = as-shot white balance.
    public var whiteBalance: WhiteBalance?

    public var vibrance: Double = 0
    public var saturation: Double = 0

    /// From 0 to 100: one slider that improves most pictures. See `EnhanceStage`.
    public var enhance: Double = 0
    /// Local contrast at a medium scale (presence) and at a fine one (texture).
    public var clarity: Double = 0
    public var structure: Double = 0
    public var dehaze: Double = 0
    /// From 0 to 100.
    public var glow: Double = 0
    public var grain: Double = 0

    /// From 0 to 100. `nil` = the engine's default for this camera.
    public var sharpness: Double?
    public var luminanceNoiseReduction: Double?
    public var colorNoiseReduction: Double?

    /// The mood the photo wears: the name of a `.cube` file, and how much of it.
    /// `nil` = none. The table itself is never stored here.
    public var lut: LUTSetting?

    public var lensCorrection: Bool = true
    /// Manual correction of the coloured fringes a lens leaves near the corners. The decoder
    /// corrects nothing on the GR III, so this is ours.
    public var aberration = ChromaticAberration()
    /// The violet halo along a hard edge, 0 to 100. Not the same fault as `aberration`, and
    /// not fixed the same way: see `PurpleFringe`.
    public var purpleFringe = PurpleFringe()
    /// Barrel and pincushion correction, -100 to 100. Positive pulls the edges back in, which
    /// is what a wide lens that bulges needs. Needs the Metal kernel: see `MetalKernels`.
    public var distortion: Double = 0
    /// Positive brightens the corners (lens correction), negative darkens them.
    public var vignetting: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        // A partial document (preset) is valid: any missing field keeps its neutral value,
        // declared once, on the properties above.
        let neutral = Adjustments()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? neutral.version
        guard version <= Adjustments.currentVersion else {
            throw RawEngineError.unsupportedAdjustmentsVersion(version)
        }
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? neutral.exposure
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? neutral.contrast
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? neutral.highlights
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? neutral.shadows
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? neutral.whites
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? neutral.blacks
        curves = try c.decodeIfPresent(Curves.self, forKey: .curves) ?? neutral.curves
        hsl = try c.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? neutral.hsl
        blackAndWhite = try c.decodeIfPresent(BlackAndWhite.self, forKey: .blackAndWhite) ?? neutral.blackAndWhite
        grading = try c.decodeIfPresent(ColorGrading.self, forKey: .grading) ?? neutral.grading
        geometry = try c.decodeIfPresent(Geometry.self, forKey: .geometry) ?? neutral.geometry
        locals = try c.decodeIfPresent([LocalAdjustment].self, forKey: .locals) ?? neutral.locals
        spots = try c.decodeIfPresent([Spot].self, forKey: .spots) ?? neutral.spots
        whiteBalance = try c.decodeIfPresent(WhiteBalance.self, forKey: .whiteBalance)
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? neutral.vibrance
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? neutral.saturation
        enhance = try c.decodeIfPresent(Double.self, forKey: .enhance) ?? neutral.enhance
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? neutral.clarity
        structure = try c.decodeIfPresent(Double.self, forKey: .structure) ?? neutral.structure
        dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? neutral.dehaze
        glow = try c.decodeIfPresent(Double.self, forKey: .glow) ?? neutral.glow
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? neutral.grain
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness)
        luminanceNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .luminanceNoiseReduction)
        colorNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .colorNoiseReduction)
        lensCorrection = try c.decodeIfPresent(Bool.self, forKey: .lensCorrection) ?? neutral.lensCorrection
        aberration = try c.decodeIfPresent(ChromaticAberration.self, forKey: .aberration) ?? neutral.aberration
        purpleFringe = try c.decodeIfPresent(PurpleFringe.self, forKey: .purpleFringe) ?? neutral.purpleFringe
        distortion = try c.decodeIfPresent(Double.self, forKey: .distortion) ?? neutral.distortion
        vignetting = try c.decodeIfPresent(Double.self, forKey: .vignetting) ?? neutral.vignetting
        lut = try c.decodeIfPresent(LUTSetting.self, forKey: .lut)

        // Whatever the file held, what comes out is a document the engine can render.
        try checkLimits()
        self = sanitized()
    }
}

public struct WhiteBalance: Codable, Equatable, Sendable {
    /// In kelvins.
    public var temperature: Double
    public var tint: Double

    public init(temperature: Double, tint: Double) {
        self.temperature = temperature
        self.tint = tint
    }
}

// MARK: - White balance editing

extension Adjustments {
    /// The white balance to develop with: the override if there is one, else the camera's.
    public func whiteBalance(orAsShot asShot: WhiteBalance) -> WhiteBalance {
        whiteBalance ?? asShot
    }

    public mutating func setTemperature(_ temperature: Double, asShot: WhiteBalance) {
        var edited = whiteBalance(orAsShot: asShot)
        edited.temperature = temperature
        setWhiteBalance(edited, asShot: asShot)
    }

    public mutating func setTint(_ tint: Double, asShot: WhiteBalance) {
        var edited = whiteBalance(orAsShot: asShot)
        edited.tint = tint
        setWhiteBalance(edited, asShot: asShot)
    }

    /// Going back to the as-shot values clears the override, so the document is neutral again.
    private mutating func setWhiteBalance(_ edited: WhiteBalance, asShot: WhiteBalance) {
        whiteBalance = edited == asShot ? nil : edited
    }
}

// MARK: - JSON

extension Adjustments {
    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Adjustments.self, from: DocumentFile.data(contentsOf: url))
    }

    public func jsonData() throws -> Data {
        try JSONEncoder.document.encode(self)
    }
}
