import Foundation

/// Enhance: one slider that improves most pictures. It opens the shadows, tames the
/// highlights, adds presence and wakes muted colors up, in proportion. It is a recipe over
/// sliders that already exist, whose stages are content-adaptive themselves: shadows only
/// lift what is dark, vibrance only boosts what is muted.
extension Adjustments {
    /// What a slider at full scale adds to each setting. Vibrance was 30: judged a notch too
    /// generous on greens and blues that are saturated already, on real photos.
    private static let enhanceRecipe: [(WritableKeyPath<Adjustments, Double> & Sendable, Double)] = [
        (\.shadows, 40), (\.highlights, -35), (\.contrast, 8), (\.dehaze, 12), (\.clarity, 22), (\.vibrance, 18),
    ]

    /// The settings the pipeline actually runs with: Enhance spent into the sliders it is
    /// made of. Folding it here, rather than running it as a stage, costs no pass of its own.
    public func foldingEnhance() -> Adjustments {
        let amount = min(max(enhance / 100, 0), 1)
        guard amount > 0 else { return self }
        var folded = self
        folded.enhance = 0
        for (keyPath, fullScale) in Self.enhanceRecipe {
            folded[keyPath: keyPath] = min(max(folded[keyPath: keyPath] + fullScale * amount, -100), 100)
        }
        return folded
    }
}
