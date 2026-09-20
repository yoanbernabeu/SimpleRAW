import CoreGraphics
import Foundation

/// A crop, in fractions of the frame it applies to, with the origin at the top-left corner
/// (the way people describe a picture, unlike Core Image's bottom-left origin).
public struct CropRect: Codable, Equatable, Sendable {
    public enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// Direction the corner points to, from the center of the rectangle.
        var direction: (x: Double, y: Double) {
            switch self {
            case .topLeft: (-1, -1)
            case .topRight: (1, -1)
            case .bottomLeft: (-1, 1)
            case .bottomRight: (1, 1)
            }
        }
    }

    /// Smallest side a crop can be dragged down to.
    public static let minimumSide = 0.05
    public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// The largest centered crop with the given width / height ratio, in normalized units.
    public static func largest(withAspect aspect: Double) -> CropRect {
        let (width, height) = aspect >= 1 ? (1, 1 / aspect) : (aspect, 1)
        return CropRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    public func moved(byX dx: Double, y dy: Double) -> CropRect {
        CropRect(
            x: min(max(x + dx, 0), 1 - width),
            y: min(max(y + dy, 0), 1 - height),
            width: width,
            height: height
        )
    }

    /// Drags one corner to a new position; the opposite corner does not move.
    /// - Parameter aspect: width / height to hold, in normalized units; `nil` for a free crop.
    public func resized(dragging corner: Corner, toX px: Double, y py: Double, aspect: Double?) -> CropRect {
        let direction = corner.direction
        let anchor = (x: direction.x > 0 ? x : maxX, y: direction.y > 0 ? y : maxY)
        // Room between the fixed corner and the edge of the frame, on the dragged side.
        let room = (x: direction.x > 0 ? 1 - anchor.x : anchor.x, y: direction.y > 0 ? 1 - anchor.y : anchor.y)

        var width = min(max((px - anchor.x) * direction.x, Self.minimumSide), room.x)
        var height = min(max((py - anchor.y) * direction.y, Self.minimumSide), room.y)
        if let aspect {
            height = width / aspect
            if height > room.y {
                height = room.y
                width = height * aspect
            }
        }
        return CropRect(
            x: direction.x > 0 ? anchor.x : anchor.x - width,
            y: direction.y > 0 ? anchor.y : anchor.y - height,
            width: width,
            height: height
        )
    }
}

/// Rotation, keystone correction, straightening and crop. They apply in that order: quarter
/// turns, then perspective, then the straighten angle (each keeping the largest frame with no
/// empty corner), then the crop, which is expressed relative to that frame.
public struct Geometry: Codable, Equatable, Sendable {
    /// Keystone correction, on the frame as it is turned.
    public var perspective = Perspective()
    /// In degrees, from -45 to +45. Positive turns the picture clockwise.
    public var straighten: Double = 0
    /// Clockwise quarter turns, always stored as 0 to 3.
    public var quarterTurns: Int = 0 {
        didSet { quarterTurns = Self.wrapped(quarterTurns) }
    }
    /// `nil` = the whole frame. A full crop is stored as `nil`.
    public var crop: CropRect? {
        didSet { if crop == .full { crop = nil } }
    }

    public init() {}

    /// A geometry that only corrects perspective: what a test or a script says in one line.
    public static func perspective(_ perspective: Perspective) -> Geometry {
        var geometry = Geometry()
        geometry.perspective = perspective
        return geometry
    }

    public init(from decoder: Decoder) throws {
        let neutral = Geometry()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        perspective = try container.decodeIfPresent(Perspective.self, forKey: .perspective) ?? neutral.perspective
        straighten = try container.decodeIfPresent(Double.self, forKey: .straighten) ?? neutral.straighten
        quarterTurns = Self.wrapped(try container.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? neutral.quarterTurns)
        let decoded = try container.decodeIfPresent(CropRect.self, forKey: .crop)
        crop = decoded == .full ? nil : decoded
    }

    public var isNeutral: Bool { self == Geometry() }

    /// The largest rectangle, with the image's own aspect ratio, that fits inside the image
    /// once it is tilted: what is left after straightening, with no empty corner.
    public static func inscribedSize(in size: CGSize, straightenedBy degrees: Double) -> CGSize {
        let radians = abs(degrees) * .pi / 180
        let (cosine, sine) = (cos(radians), sin(radians))
        let scale = min(
            size.width / (size.width * cosine + size.height * sine),
            size.height / (size.width * sine + size.height * cosine)
        )
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The frame the crop is relative to: turned, corrected and straightened, not yet cropped.
    public func frameSize(for imageSize: CGSize) -> CGSize {
        let turned = quarterTurns % 2 == 0 ? imageSize : CGSize(width: imageSize.height, height: imageSize.width)
        // A keystone correction keeps the shape of the frame, so it is one factor on both sides.
        let scale = perspective.isNeutral || turned.width == 0 ? 1 : perspective.scale(ofShape: turned.height / turned.width)
        let corrected = CGSize(width: turned.width * scale, height: turned.height * scale)
        return Self.inscribedSize(in: corrected, straightenedBy: straighten)
    }

    /// Size of the final picture for an upright image of `imageSize`.
    public func outputSize(for imageSize: CGSize) -> CGSize {
        let frame = frameSize(for: imageSize)
        let crop = crop ?? .full
        return CGSize(width: (frame.width * crop.width).rounded(), height: (frame.height * crop.height).rounded())
    }

    /// Turns the picture by a quarter, carrying the crop along so that it keeps framing the
    /// same part of the scene.
    public mutating func turn(clockwise: Bool) {
        quarterTurns += clockwise ? 1 : -1
        guard let rect = crop else { return }
        crop = clockwise
            ? CropRect(x: 1 - rect.maxY, y: rect.x, width: rect.height, height: rect.width)
            : CropRect(x: rect.y, y: 1 - rect.maxX, width: rect.height, height: rect.width)
    }

    private static func wrapped(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }

    /// Whole pixels, rounded inward: a fractional edge would export a transparent fringe.
    /// Shared by every stage that cuts a frame out of a picture.
    static func integral(_ rect: CGRect) -> CGRect {
        let origin = CGPoint(x: rect.minX.rounded(.up), y: rect.minY.rounded(.up))
        return CGRect(x: origin.x, y: origin.y, width: rect.maxX.rounded(.down) - origin.x, height: rect.maxY.rounded(.down) - origin.y)
    }
}
