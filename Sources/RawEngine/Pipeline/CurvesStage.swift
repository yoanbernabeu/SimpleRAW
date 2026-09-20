import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies the point curves: the master curve, then one curve per channel, baked into a
/// single lookup table evaluated on display (sRGB-encoded) levels.
public struct CurvesStage: PipelineStage {
    /// Fine enough that the linear interpolation between samples is invisible.
    static let tableSize = 1024

    /// Curves rarely change from one frame to the next, while every gesture runs this stage:
    /// the same `Data` also spares Core Image a new texture.
    private let cache = RecentValuesCache<Curves, Data>()

    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let curves = adjustments.curves
        guard !curves.isIdentity else { return image }

        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = cache.value(for: curves) { Self.table(for: curves) }
        filter.curvesDomain = CIVector(x: 0, y: 1)
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return filter.outputImage ?? image
    }

    /// Red, green and blue interleaved: each channel curve evaluated on what the master curve
    /// made of the level.
    static func table(for curves: Curves) -> Data {
        let master = curves.rgb.lookupTable(size: tableSize)
        // The master curve may go down: its output is not sorted, so channels are evaluated
        // level by level, with their tangents computed once.
        let channels = [curves.red, curves.green, curves.blue].map(Curve.Evaluator.init)
        var table = [Float]()
        table.reserveCapacity(tableSize * 3)
        for level in master {
            for channel in channels {
                table.append(Float(channel.value(at: Double(level))))
            }
        }
        return table.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
