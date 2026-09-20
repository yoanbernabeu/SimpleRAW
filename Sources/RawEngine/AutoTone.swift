import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// What Auto needs to know about a picture: where its tones sit, on display levels (0...1),
/// and how colorful it is.
public struct ToneStatistics: Equatable, Sendable {
    public var p1: Double, p5: Double, p25: Double, p50: Double, p75: Double, p95: Double, p99: Double
    /// Mean saturation, from 0 (gray) to 1.
    public var meanSaturation: Double

    public init(p1: Double, p5: Double, p25: Double, p50: Double, p75: Double, p95: Double, p99: Double, meanSaturation: Double) {
        self.p1 = p1; self.p5 = p5; self.p25 = p25; self.p50 = p50
        self.p75 = p75; self.p95 = p95; self.p99 = p99
        self.meanSaturation = meanSaturation
    }
}

/// The light settings Auto comes up with.
public struct AutoToneResult: Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var vibrance: Double

    public init(
        exposure: Double, contrast: Double, highlights: Double, shadows: Double,
        whites: Double, blacks: Double, vibrance: Double
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.vibrance = vibrance
    }

    /// Replaces the light sliders and vibrance; everything else is left as it is.
    public func apply(to adjustments: inout Adjustments) {
        adjustments.exposure = exposure
        adjustments.contrast = contrast
        adjustments.highlights = highlights
        adjustments.shadows = shadows
        adjustments.whites = whites
        adjustments.blacks = blacks
        adjustments.vibrance = vibrance
    }
}

/// Auto: a pure decision. Aim the median at a pleasant mid-tone without blowing highlights,
/// then give the picture true blacks and whites, open what is blocked, recover what is hot,
/// and add contrast and color where they are lacking. Restrained on purpose: a good picture
/// must come out barely touched.
public enum AutoTone {
    static let targetMedian = 0.45
    static let displayGamma = 2.2

    /// Long edge of the picture Auto looks at: tones need no more, and one size for every
    /// front end means one answer for a photo, in the app as on the command line.
    static let analysisSide = 512.0

    static func analysisScale(for imageSize: CGSize) -> Float {
        PreviewScale.factor(for: imageSize, fitting: CGSize(width: analysisSide, height: analysisSide))
    }

    /// Auto for a photo: the one way in. It looks at the picture as decoded, with neutral
    /// settings, so that running it again adds nothing up.
    public static func settings(for source: RawSource) throws -> AutoToneResult {
        let neutral = try source.image(scaleFactor: analysisScale(for: source.info.imageSize))
        return settings(for: try ToneAnalyzer().statistics(of: neutral))
    }

    public static func settings(for stats: ToneStatistics) -> AutoToneResult {
        func linear(_ level: Double) -> Double { pow(max(level, 0.001), displayGamma) }
        func display(_ value: Double) -> Double { pow(min(max(value, 0), 4), 1 / displayGamma) }

        // Exposure: toward the target median, damped, and held back by existing highlights.
        let wanted = log2(linear(targetMedian) / linear(stats.p50)) * 0.75
        let headroom = log2(linear(0.98) / linear(stats.p99)) + 0.6
        let exposure = clamp(min(wanted, max(headroom, 0)) , -2, 2)
        let moved = wanted >= 0 ? exposure : clamp(wanted, -2, 2)

        // Where the tones end up once exposure is applied.
        let gain = pow(2, moved)
        func shifted(_ level: Double) -> Double { display(linear(level) * gain) }
        let (low, dark, quarter, threeQuarters, bright, high) =
            (shifted(stats.p1), shifted(stats.p5), shifted(stats.p25), shifted(stats.p75), shifted(stats.p95), shifted(stats.p99))

        let whites = high < 0.92 ? clamp((0.95 - high) * 220, 0, 60) : 0
        let blacks = low > 0.05 ? -clamp((low - 0.02) * 260, 0, 60) : 0
        // Exposure that could not be given because of the highlights is given to the shadows.
        let owed = max(0, wanted - moved)
        let shadows = clamp((dark < 0.1 ? (0.1 - dark) * 350 : 0) + owed * 45, 0, 70)
        // Highlights that are hot once exposure is set, or that were clipped to begin with: a
        // RAW file has headroom there that only recovery brings back.
        let clippedAtCapture = stats.p99 >= 0.99 ? 35.0 : 0
        let highlights = -max(bright > 0.9 ? clamp((bright - 0.9) * 600, 0, 70) : 0, clippedAtCapture)
        let spread = threeQuarters - quarter
        let contrast = spread < 0.3 ? clamp((0.3 - spread) * 160, 0, 35) : 0
        let vibrance = clamp((0.45 - stats.meanSaturation) * 60, 0, 30)

        return AutoToneResult(
            exposure: (moved * 20).rounded() / 20, contrast: contrast.rounded(), highlights: highlights.rounded(),
            shadows: shadows.rounded(), whites: whites.rounded(), blacks: blacks.rounded(), vibrance: vibrance.rounded()
        )
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}

/// Measures `ToneStatistics` on the GPU. Cheap to create and safe to share: the context
/// belongs to `LevelsReader`, which every analysis goes through.
public struct ToneAnalyzer: Sendable {
    public init() {}

    public func statistics(of image: CIImage) throws -> ToneStatistics {
        let displayed = try LevelsReader.displayed(image)

        // Red carries luminance.
        let luma = CIFilter.colorMatrix()
        luma.inputImage = displayed
        luma.rVector = Rec709.vector
        luma.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        luma.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let gray = luma.outputImage else { throw RawEngineError.analysisFailed }
        let levels = try LevelsReader.shared.levels(ofDisplayed: gray, extent: image.extent)[0]

        var cumulative = 0.0
        var percentiles: [Double: Double] = [:]
        for (bin, share) in levels.enumerated() {
            cumulative += Double(share)
            for target in [0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99] where percentiles[target] == nil && cumulative >= target {
                percentiles[target] = Double(bin) / Double(LevelsReader.binCount - 1)
            }
        }
        func level(_ target: Double) -> Double { percentiles[target] ?? 1 }

        return ToneStatistics(
            p1: level(0.01), p5: level(0.05), p25: level(0.25), p50: level(0.5), p75: level(0.75), p95: level(0.95), p99: level(0.99),
            meanSaturation: try meanSaturation(of: displayed, extent: image.extent)
        )
    }

    /// (max - min) / max over a coarse grid of 24 × 24 samples read back from the GPU. Stock
    /// filters have no per-pixel maximum of the channels, and no picture needs more than a
    /// few hundred samples to say how colorful it is. The samples are picked, not averaged:
    /// the picture is scaled down without being filtered first, which is fine for a mean.
    private func meanSaturation(of image: CIImage, extent: CGRect) throws -> Double {
        let side = 24
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / extent.width, y: CGFloat(side) / extent.height))
        var pixels = [Float](repeating: 0, count: side * side * 4)
        LevelsReader.shared.context.render(scaled, toBitmap: &pixels, rowBytes: side * 16, bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBAf, colorSpace: nil)
        let saturations = stride(from: 0, to: pixels.count, by: 4).map { index -> Double in
            let (high, low) = (max(pixels[index], pixels[index + 1], pixels[index + 2]), min(pixels[index], pixels[index + 1], pixels[index + 2]))
            return high > 0.02 ? Double((high - low) / high) : 0
        }
        return saturations.reduce(0, +) / Double(saturations.count)
    }
}
