import CoreImage

/// Color grading: a tint and a luminance offset for shadows, midtones and highlights.
public struct ColorGradingStage: PipelineStage {
    private let cache = RecentValuesCache<ColorGrading, ColorCube>()

    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let grading = adjustments.grading
        guard !grading.isNeutral else { return image }
        let cube = cache.value(for: grading) {
            let transform = ColorGradingTransform(grading)
            return ColorCube { transform.apply(to: $0) }
        }
        return cube.apply(to: image)
    }
}
