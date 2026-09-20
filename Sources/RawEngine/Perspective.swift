import Foundation

/// Keystone correction: the converging verticals of a building shot from below, and the same
/// thing sideways. Pure geometry, no Core Image — this is where the rule is decided and
/// `GeometryStage` only hands the corners to the GPU.
///
/// Both sliders run from -100 to +100. A correction moves the two corners of one edge outward
/// and the two opposite ones inward by as much.
///
/// The middle of the picture is then brought back to the middle of the frame. It does not go
/// there on its own: under a projective map the center of a rectangle lands where the
/// diagonals of the trapezoid cross, which is off towards the narrow side, so the picture
/// would slide up the screen as the slider moves. What the photographer aimed at staying
/// where they aimed it is worth the few percent of frame it costs.
///
/// Like straightening, it leaves triangles of nothing at the edges, and like straightening the
/// picture is cut back to the largest frame of the same shape that holds no such triangle.
/// `scale(ofShape:)` is that fraction: exactly `1 - amount` on one axis alone.
public struct Perspective: Codable, Equatable, Sendable {
    /// Positive leans the top of the frame out: what a building photographed from below needs.
    public var vertical: Double = 0
    /// Positive leans the left of the frame out.
    public var horizontal: Double = 0

    /// How far a slider at full scale moves a corner, as a fraction of the half-width. Beyond
    /// this a correction throws away more picture than it is worth: at 0.35 a full slider
    /// still keeps three quarters of the frame.
    public static let shift = 0.35

    public init(vertical: Double = 0, horizontal: Double = 0) {
        self.vertical = vertical
        self.horizontal = horizontal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vertical = try container.decodeIfPresent(Double.self, forKey: .vertical) ?? 0
        horizontal = try container.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0
    }

    public var isNeutral: Bool { self == Perspective() }

    /// A corner of the frame, in units of the half-width, with the origin at the center and
    /// y pointing up.
    public typealias Point = (x: Double, y: Double)

    /// The four corners of the tilted frame, clockwise from the top left, with the middle of
    /// the picture at the origin.
    /// - Parameter shape: half-height over half-width of the picture being corrected.
    public func corners(ofShape shape: Double) -> [Point] {
        let (v, h) = (Self.shift * Slider.bipolar(vertical), Self.shift * Slider.bipolar(horizontal))
        // A corner is pushed out or pulled in by the slider of the *other* axis: the top edge
        // narrows as the bottom widens, which is what straightening a keystone looks like.
        let tilted: [Point] = [(-1.0, 1.0), (1, 1), (1, -1), (-1, -1)].map { sx, sy in
            (x: sx * (1 - v * sy), y: sy * shape * (1 - h * sx))
        }
        // Where the middle of the picture lands: a projective map takes the crossing of the
        // rectangle's diagonals to the crossing of the quadrilateral's. Brought back to zero.
        let middle = Self.crossingOfDiagonals(tilted)
        return tilted.map { (x: $0.x - middle.x, y: $0.y - middle.y) }
    }

    /// Where the two diagonals of a convex quadrilateral meet.
    private static func crossingOfDiagonals(_ corners: [Point]) -> Point {
        let (a, b, c, d) = (corners[0], corners[2], corners[1], corners[3])
        let (r, s) = ((x: b.x - a.x, y: b.y - a.y), (x: d.x - c.x, y: d.y - c.y))
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else { return (x: 0, y: 0) }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
        return (x: a.x + t * r.x, y: a.y + t * r.y)
    }

    /// The frame comes in steps of two percent. A drag moves the slider sixty times a second,
    /// and a frame that is a different size every time asks Core Image for a different region
    /// of the picture every time: it then renders and keeps a whole new set of blurs for each,
    /// a few hundred megabytes a frame, and a single drag ran the machine out of memory. In
    /// steps, a drag asks for a handful of regions however long it lasts.
    static let frameStep = 0.02

    /// The fraction of the picture the correction keeps: the largest centered frame of the
    /// same shape that fits inside the tilted one, cut down to the step below.
    ///
    /// With one axis alone the edges of the trapezoid are straight lines and the answer before
    /// stepping is exactly `1 - amount`; with both it is found by halving, which costs nothing
    /// and cannot be wrong about a shape it has no formula for. Always rounded **down**, so
    /// the frame stays inside the picture whatever the rounding does.
    public func scale(ofShape shape: Double) -> Double {
        guard !isNeutral else { return 1 }
        let corners = corners(ofShape: shape)
        var (small, large) = (0.0, 1.0)
        for _ in 0..<40 {
            let middle = (small + large) / 2
            if fits(middle, shape: shape, in: corners) { small = middle } else { large = middle }
        }
        return (small / Self.frameStep).rounded(.down) * Self.frameStep
    }

    private func fits(_ scale: Double, shape: Double, in corners: [Point]) -> Bool {
        [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)].allSatisfy { sx, sy in
            Self.contains((x: sx * scale, y: sy * scale * shape), in: corners)
        }
    }

    /// Whether a point is inside a convex quadrilateral: it is on the same side of every edge.
    public static func contains(_ point: Point, in corners: [Point]) -> Bool {
        var sign = 0.0
        for index in corners.indices {
            let (a, b) = (corners[index], corners[(index + 1) % corners.count])
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 1e-12 { continue }
            if sign == 0 { sign = cross } else if sign * cross < 0 { return false }
        }
        return true
    }
}
