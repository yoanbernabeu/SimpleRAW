import CoreImage

/// The HSL panel: hue, saturation and luminance per color band.
public struct HSLStage: PipelineStage {
    private let cache = RecentValuesCache<HSLAdjustments, ColorCube>()

    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let settings = adjustments.hsl
        guard !settings.isNeutral else { return image }
        let cube = cache.value(for: settings) {
            let transform = HSLTransform(settings)
            return ColorCube { transform.apply(to: $0) }
        }
        return cube.apply(to: image)
    }
}
