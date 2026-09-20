import CoreGraphics
import Foundation

/// Straightening by drawing: a line is traced along something that ought to be level — a
/// horizon, the foot of a wall, the edge of a door — and the picture is turned until it is.
///
/// Pure, and in pixels: a line drawn across a picture that is wider than it is high has an
/// angle only once both axes are on the same scale, which is why the caller converts before
/// asking. Points come with y pointing **down**, as a view reports them.
public enum LevelTool {
    /// Shorter than this, in pixels, and the line says nothing: a click is not a direction.
    public static let minimumLength = 12.0

    /// How much to add to `Geometry.straighten` so that the line drawn becomes level.
    ///
    /// A line within 45° of the horizontal is taken for a horizon; anything steeper is taken
    /// for an upright, and is brought to the vertical instead. Nobody says which they meant,
    /// and nobody has to: past 45° the other reading would turn the picture on its side.
    ///
    /// - Returns: degrees, positive turning the picture clockwise, or `nil` for a line too
    ///   short to mean anything.
    public static func straightening(from start: CGPoint, to end: CGPoint) -> Double? {
        let (dx, dy) = (Double(end.x - start.x), Double(end.y - start.y))
        guard hypot(dx, dy) >= minimumLength else { return nil }
        // Back to y up, so that the angle reads the way it is drawn.
        let angle = atan2(-dy, dx) * 180 / .pi
        // The same line drawn the other way round is the same line.
        let folded = angle > 90 ? angle - 180 : (angle <= -90 ? angle + 180 : angle)
        // Within 45° of level, bring it to level; past that, bring it to the upright.
        return abs(folded) <= 45 ? folded : folded - (folded > 0 ? 90 : -90)
    }

    /// The straightening a line asks for, added to what the picture already has and held to
    /// what the slider can say. The line is drawn on the picture as it is now, so the two add.
    public static func straighten(_ current: Double, by drawn: Double, limit: Double = 45) -> Double {
        min(max(current + drawn, -limit), limit)
    }
}
