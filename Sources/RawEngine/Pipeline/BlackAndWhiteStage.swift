import CoreImage

/// Black and white with a channel mixer. Runs after the color stages, so that HSL work still
/// shapes the tones, and before color grading, so that a black and white can be toned.
public struct BlackAndWhiteStage: PipelineStage {
    private let cache = RecentValuesCache<BlackAndWhite, ColorCube>()

    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let settings = adjustments.blackAndWhite
        guard settings.isEnabled else { return image }
        let cube = cache.value(for: settings) {
            let transform = BlackAndWhiteTransform(settings)
            return ColorCube { transform.apply(to: $0) }
        }
        return cube.apply(to: image)
    }
}
