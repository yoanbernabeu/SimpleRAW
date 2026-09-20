import CoreGraphics

/// Turns contrast / whites / blacks (and highlight brightening) into a 5-point curve,
/// expressed in perceptual space (sRGB encoding).
enum ToneCurve {
    static let identity: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0.25, y: 0.25),
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75),
        CGPoint(x: 1, y: 1),
    ]

    /// Maximum travel of an endpoint (blacks, whites).
    private static let endpointRange = 0.12
    private static let contrastRange = 0.08
    private static let highlightsRange = 0.10

    /// `nil` when the curve is neutral: the stage can then be skipped.
    static func points(for adjustments: Adjustments) -> [CGPoint]? {
        let contrast = Slider.bipolar(adjustments.contrast)
        let whites = Slider.bipolar(adjustments.whites)
        let blacks = Slider.bipolar(adjustments.blacks)
        // Negative highlights are handled by the adaptive stage of the pipeline.
        let highlights = max(0, Slider.bipolar(adjustments.highlights))

        guard contrast != 0 || whites != 0 || blacks != 0 || highlights != 0 else { return nil }

        var points = identity
        // Blacks: negative = clipping (the point slides along the x axis), positive = fade.
        points[0] = blacks < 0
            ? CGPoint(x: -blacks * endpointRange, y: 0)
            : CGPoint(x: 0, y: blacks * endpointRange)
        // Whites: positive = clipping, negative = dulled whites.
        points[4] = whites > 0
            ? CGPoint(x: 1 - whites * endpointRange, y: 1)
            : CGPoint(x: 1, y: 1 + whites * endpointRange)
        points[1].y -= contrast * contrastRange
        points[3].y += contrast * contrastRange + highlights * highlightsRange

        // The curve must stay monotonic, whatever the slider combination.
        points[3].y = min(points[3].y, points[4].y)
        for i in 1..<points.count {
            points[i].y = max(points[i].y, points[i - 1].y)
        }
        return points
    }
}
