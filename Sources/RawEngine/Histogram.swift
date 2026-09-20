import CoreImage
import CoreImage.CIFilterBuiltins

/// Per-channel distribution of an image, display-referred (sRGB-encoded levels), which is
/// what a photographer expects to read: mid-gray sits in the middle.
public struct Histogram: Equatable, Sendable {
    public static let binCount = LevelsReader.binCount

    /// Share of pixels in an end bin above which the channel is considered clipped.
    static let clippingThreshold: Float = 0.001

    /// Bin heights, scaled so that the tallest bin across all channels is 1.
    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]
    public let clipsShadows: Bool
    public let clipsHighlights: Bool

    /// - Parameter fractions: per channel, the share of pixels falling in each bin.
    init(fractions: [[Float]]) {
        let tallest = fractions.joined().max() ?? 0
        let scaled = fractions.map { channel in channel.map { tallest > 0 ? $0 / tallest : 0 } }
        red = scaled[0]
        green = scaled[1]
        blue = scaled[2]
        clipsShadows = fractions.contains { ($0.first ?? 0) > Histogram.clippingThreshold }
        clipsHighlights = fractions.contains { ($0.last ?? 0) > Histogram.clippingThreshold }
    }
}

/// Measures a `Histogram` on the GPU. Cheap to create and safe to share: the context belongs
/// to `LevelsReader`, which every analysis goes through.
public struct HistogramAnalyzer: Sendable {
    public init() {}

    public func histogram(of image: CIImage) throws -> Histogram {
        Histogram(fractions: try LevelsReader.shared.levels(of: image))
    }
}
