import CoreGraphics

/// Where the mouse goes during a scripted gesture.
///
/// Every slider, every overlay and every stroke of this app is tested at the level of the
/// session: a test calls the method the gesture calls. None of that says whether the gesture
/// *reaches* the method — whether a view above swallows the press, whether a handle sits where
/// the picture is, whether a tool takes the click at all. The only way to know is to put the
/// mouse down and watch what changes, which is what `GestureScript` does; this is the
/// arithmetic it does it with, kept here because it is pure and therefore testable.
enum MousePath {
    /// The points of a straight drag, both ends included.
    static func straight(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 0 else { return [start, end] }
        return (0...steps).map { step in
            let share = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: start.x + (end.x - start.x) * share, y: start.y + (end.y - start.y) * share)
        }
    }

    /// A drag through several places, each corner passed once.
    static func through(_ waypoints: [CGPoint], stepsEach: Int) -> [CGPoint] {
        guard let first = waypoints.first else { return [] }
        return zip(waypoints, waypoints.dropFirst()).reduce(into: [first]) { points, leg in
            points += straight(from: leg.0, to: leg.1, steps: stepsEach).dropFirst()
        }
    }

    /// A place inside a view, from the frame SwiftUI reports (origin at the top left of the
    /// window) to what an `NSEvent` wants (origin at the bottom left of the content view).
    /// `share` is relative to the view: `(0.5, 0.5)` is its middle, `(0, 0.5)` its left edge.
    static func inWindow(_ frame: CGRect, at share: CGPoint, contentHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: frame.minX + frame.width * share.x,
            y: contentHeight - (frame.minY + frame.height * share.y)
        )
    }
}
