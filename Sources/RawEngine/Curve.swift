import Foundation

/// A tone curve drawn through control points, on display levels (0 = black, 1 = white).
///
/// Interpolation is monotone cubic (Fritsch–Carlson): smooth like a spline, but it never
/// overshoots between points, so increasing points can never invert tones.
public struct Curve: Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Closest two points may get on the x axis while editing.
    static let minimumGap = 0.01

    /// Always sorted by `x`, with distinct `x` values, and at least two points.
    public private(set) var points: [Point]

    public static let identity = Curve(points: [Point(x: 0, y: 0), Point(x: 1, y: 1)])

    public init(points: [Point]) {
        var sorted: [Point] = []
        for point in points.sorted(by: { $0.x < $1.x }) {
            if sorted.last?.x == point.x { sorted.removeLast() }
            sorted.append(point)
        }
        self.points = sorted.count >= 2 ? sorted : Curve.identity.points
    }

    public var isIdentity: Bool { self == .identity }

    /// Points inside the unit square and at least `minimumGap` apart, as editing keeps them:
    /// a secant between two points a hair apart is infinite, and the table full of NaN.
    func sanitized() -> Curve {
        var kept: [Point] = []
        for point in points.map({ Point(x: $0.x.bounded(to: 0...1, else: 0), y: $0.y.bounded(to: 0...1, else: 0)) }).sorted(by: { $0.x < $1.x }) {
            if let last = kept.last, point.x - last.x < Self.minimumGap { continue }
            kept.append(point)
        }
        return Curve(points: kept)
    }
}

// MARK: - Evaluation

extension Curve {
    /// Flat beyond the first and last points, clamped to 0...1.
    public func value(at x: Double) -> Double {
        Evaluator(self).value(at: x)
    }

    /// The curve sampled at `size` evenly spaced levels, from 0 to 1. The way to evaluate a
    /// curve more than a few times: tangents are worked out once for the whole table.
    public func lookupTable(size: Int) -> [Float] {
        let evaluator = Evaluator(self)
        // Levels only go up, so the segment they fall in only moves forward.
        var upper = 1
        return (0..<size).map { index in
            let x = Double(index) / Double(max(size - 1, 1))
            while upper < points.count - 1, points[upper].x <= x { upper += 1 }
            return Float(evaluator.value(at: x, upper: upper))
        }
    }

    /// A curve ready to be evaluated many times: its tangents are computed once, not on
    /// every level, which a table of a thousand entries rebuilt on every frame cannot afford.
    struct Evaluator {
        private let points: [Point]
        private let tangents: [Double]

        init(_ curve: Curve) {
            points = curve.points
            tangents = Self.tangents(of: curve.points)
        }

        func value(at x: Double) -> Double {
            value(at: x, upper: points.firstIndex { $0.x > x } ?? points.count - 1)
        }

        /// - Parameter upper: index of the first point beyond `x`, for callers that know it.
        fileprivate func value(at x: Double, upper: Int) -> Double {
            guard let first = points.first, let last = points.last else { return x }
            if x <= first.x { return Curve.clamped(first.y) }
            if x >= last.x { return Curve.clamped(last.y) }

            let (p0, p1) = (points[upper - 1], points[upper])
            let h = p1.x - p0.x
            let t = (x - p0.x) / h
            let (t2, t3) = (t * t, t * t * t)
            let y = (2 * t3 - 3 * t2 + 1) * p0.y
                + (t3 - 2 * t2 + t) * h * tangents[upper - 1]
                + (-2 * t3 + 3 * t2) * p1.y
                + (t3 - t2) * h * tangents[upper]
            return Curve.clamped(y)
        }

        /// Fritsch–Carlson tangents: secant averages, flattened wherever they would overshoot.
        private static func tangents(of points: [Point]) -> [Double] {
            let count = points.count
            guard count >= 2 else { return [Double](repeating: 0, count: count) }
            let secants = (0..<count - 1).map { (points[$0 + 1].y - points[$0].y) / (points[$0 + 1].x - points[$0].x) }
            var tangents = (0..<count).map { index -> Double in
                if index == 0 { return secants[0] }
                if index == count - 1 { return secants[count - 2] }
                let (before, after) = (secants[index - 1], secants[index])
                return before * after <= 0 ? 0 : (before + after) / 2
            }
            for (index, secant) in secants.enumerated() {
                guard secant != 0 else {
                    tangents[index] = 0
                    tangents[index + 1] = 0
                    continue
                }
                let (a, b) = (tangents[index] / secant, tangents[index + 1] / secant)
                let magnitude = a * a + b * b
                if magnitude > 9 {
                    let scale = 3 / magnitude.squareRoot()
                    tangents[index] = scale * a * secant
                    tangents[index + 1] = scale * b * secant
                }
            }
            return tangents
        }
    }

    fileprivate static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - Editing

extension Curve {
    /// - Returns: the index of the new point.
    @discardableResult
    public mutating func insert(_ point: Point) -> Int {
        self = Curve(points: points.filter { $0.x != point.x } + [Self.clamped(point)])
        return points.firstIndex { $0.x == Self.clamped(point).x } ?? 0
    }

    /// Moves a point, keeping it inside the unit square and between its neighbours.
    public mutating func move(at index: Int, to target: Point) {
        guard points.indices.contains(index) else { return }
        let lower = index > 0 ? points[index - 1].x + Self.minimumGap : 0
        let upper = index < points.count - 1 ? points[index + 1].x - Self.minimumGap : 1
        var moved = Self.clamped(target)
        moved.x = min(max(moved.x, lower), max(lower, upper))
        points[index] = moved
    }

    /// End points anchor the curve: they can move, not go.
    public mutating func remove(at index: Int) {
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
    }

    /// The point a user grabbed, if any lies within `distance` of `location`.
    public func indexOfPoint(near location: Point, within distance: Double) -> Int? {
        let candidates = points.indices.map { ($0, hypot(points[$0].x - location.x, points[$0].y - location.y)) }
        return candidates.filter { $0.1 <= distance }.min { $0.1 < $1.1 }?.0
    }

    private static func clamped(_ point: Point) -> Point {
        Point(x: clamped(point.x), y: clamped(point.y))
    }
}

// MARK: - JSON

extension Curve: Codable {
    private enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try container.decode([Point].self, forKey: .points))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }
}

/// The master curve and one curve per channel. The master applies first.
public struct Curves: Codable, Equatable, Sendable {
    public var rgb = Curve.identity
    public var red = Curve.identity
    public var green = Curve.identity
    public var blue = Curve.identity

    public init() {}

    public init(from decoder: Decoder) throws {
        let neutral = Curves()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try container.decodeIfPresent(Curve.self, forKey: .rgb) ?? neutral.rgb
        red = try container.decodeIfPresent(Curve.self, forKey: .red) ?? neutral.red
        green = try container.decodeIfPresent(Curve.self, forKey: .green) ?? neutral.green
        blue = try container.decodeIfPresent(Curve.self, forKey: .blue) ?? neutral.blue
    }

    public var isIdentity: Bool { self == Curves() }
}
