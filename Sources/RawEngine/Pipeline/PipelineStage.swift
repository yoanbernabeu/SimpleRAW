import CoreImage

/// One processing step of the development pipeline. Each stage reads only the settings it
/// cares about from `Adjustments`, and returns the image untouched when they are neutral.
public protocol PipelineStage: Sendable {
    func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage
}

/// An ordered list of stages. Adding a treatment = adding a stage, leaving the others alone.
public struct DevelopPipeline: Sendable {
    public let stages: [any PipelineStage]

    public init(stages: [any PipelineStage]) {
        self.stages = stages
    }

    /// Order matters: optical corrections on linear light first, then tone, then color, and
    /// geometry last so that everything before it sees the uncropped frame.
    public static let standard = DevelopPipeline(stages: [
        VignettingStage(),
        LensCorrectionStage(),
        SpotRemovalStage(),
        HighlightsShadowsStage(),
        ToneCurveStage(),
        DehazeStage(),
        LocalContrastStage(),
        LocalAdjustmentsStage(),
        CurvesStage(),
        HSLStage(),
        VibranceStage(),
        SaturationStage(),
        BlackAndWhiteStage(),
        ColorGradingStage(),
        LUTStage(),
        GlowStage(),
        GrainStage(),
        GeometryStage(),
    ])

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        // Stages see the effective settings, with one-gesture tools spent into the sliders.
        let effective = adjustments.foldingEnhance()
        return stages.reduce(image) { $1.apply(effective, to: $0) }
    }
}
