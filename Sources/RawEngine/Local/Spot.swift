import Foundation

/// A blemish to remove: the pixels around `source` are copied over `target`.
///
/// A dust spot is a single point. A power line, a scratch, a stray branch is not: it is a
/// line, and chasing it with circles leaves a chain of half-covered lumps. So a spot can also
/// carry the rest of a line drawn along it, healed in one go, with the same offset from end
/// to end — which is what makes the copied strip look like a piece of the picture and not a
/// row of patches.
public struct Spot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Where the line starts, and the point the source is measured from.
    public var target: NormalizedPoint
    public var source: NormalizedPoint
    /// In fractions of the frame's long edge, so that the spot is round on screen.
    public var radius: Double
    /// From 0 (hard edge) to 1 (fades all the way from the center).
    public var feather: Double
    /// The rest of the line, after `target`. Empty for a spot, which is one point.
    public var path: [NormalizedPoint]

    public init(
        id: UUID = UUID(), target: NormalizedPoint, source: NormalizedPoint, radius: Double,
        feather: Double = 0.4, path: [NormalizedPoint] = []
    ) {
        self.id = id
        self.target = target
        self.source = source
        self.radius = radius
        self.feather = feather
        self.path = path
    }

    /// Documents written before a spot could be a line still open, as one point.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        target = try container.decode(NormalizedPoint.self, forKey: .target)
        source = try container.decode(NormalizedPoint.self, forKey: .source)
        radius = try container.decode(Double.self, forKey: .radius)
        feather = try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0.4
        path = try container.decodeIfPresent([NormalizedPoint].self, forKey: .path) ?? []
    }

    /// Whether it is a line rather than a point.
    public var isLine: Bool { !path.isEmpty }

    /// Every point of the line, the first one included: what the mask is drawn along.
    public var points: [NormalizedPoint] { [target] + path }

    /// How far the copied pixels come from, as a vector in normalized units. One offset for
    /// the whole line: the strip that is copied stays a strip of the picture.
    public var offset: (x: Double, y: Double) {
        (x: source.x - target.x, y: source.y - target.y)
    }
}
