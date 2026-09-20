import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A point of the picture, in fractions of its uncropped, upright frame, with the origin at
/// the top-left corner.
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The same point in the coordinates of a Core Image extent (origin bottom-left).
    func location(in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + x * extent.width, y: extent.minY + (1 - y) * extent.height)
    }
}

/// A graduated filter: full effect on the `start` side, none past `end`, a linear ramp
/// between the two, perpendicular to the line they draw.
public struct LinearMask: Codable, Equatable, Sendable {
    public var start: NormalizedPoint
    public var end: NormalizedPoint

    public init(start: NormalizedPoint, end: NormalizedPoint) {
        self.start = start
        self.end = end
    }

    /// - Parameter aspect: width / height of the frame. Distances are measured in pixels, so
    ///   that the ramp is perpendicular to its axis on screen, not in normalized space.
    public func value(at point: NormalizedPoint, aspect: Double) -> Double {
        let axis = (x: (end.x - start.x) * aspect, y: end.y - start.y)
        let offset = (x: (point.x - start.x) * aspect, y: point.y - start.y)
        let length = axis.x * axis.x + axis.y * axis.y
        guard length > 0 else { return 1 }
        let progress = (offset.x * axis.x + offset.y * axis.y) / length
        return 1 - min(max(progress, 0), 1)
    }
}

/// An elliptical filter: full effect inside, fading out over the `feather` share of its
/// radius. Inverted, it affects everything but the ellipse.
public struct RadialMask: Codable, Equatable, Sendable {
    public var center: NormalizedPoint
    /// In fractions of the frame's width and height.
    public var radiusX: Double
    public var radiusY: Double
    /// From 0 (hard edge) to 1 (fades all the way from the center).
    public var feather: Double
    public var isInverted: Bool

    public init(center: NormalizedPoint, radiusX: Double, radiusY: Double, feather: Double = 0.5, isInverted: Bool = false) {
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.feather = feather
        self.isInverted = isInverted
    }

    public func value(at point: NormalizedPoint) -> Double {
        guard radiusX > 0, radiusY > 0 else { return isInverted ? 1 : 0 }
        let distance = hypot((point.x - center.x) / radiusX, (point.y - center.y) / radiusY)
        let solid = 1 - min(max(feather, 0), 1)
        let inside: Double = distance <= solid ? 1 : distance >= 1 ? 0 : 1 - (distance - solid) / (1 - solid)
        return isInverted ? 1 - inside : inside
    }
}

/// The kinds of mask there are, under the name people know them by.
public enum MaskKind: String, CaseIterable, Identifiable, Sendable {
    case linear = "Gradient"
    case radial = "Radial"
    case brush = "Brush"
    /// What the picture is of, found by the machine.
    case subject = "Subject"
    /// A person in the frame, found by the machine.
    case person = "Person"

    public var id: Self { self }

    /// Whether the machine has to look at the picture before this mask means anything.
    public var isDetected: Bool { self == .subject || self == .person }
}

public enum Mask: Equatable, Sendable {
    case linear(LinearMask)
    case radial(RadialMask)
    case brush(BrushMask)
    case detected(DetectedMask)

    public var kind: MaskKind {
        switch self {
        case .linear: .linear
        case .radial: .radial
        case .brush: .brush
        case .detected(let mask): mask.subject == .person ? .person : .subject
        }
    }

    /// The mask as a grayscale image covering `extent`: white where the effect is full.
    ///
    /// A found mask reads its picture from `MaskRasterStore`. Not there yet — being computed,
    /// or computed for a photo that is no longer open — it is black, which is a mask that
    /// changes nothing: the picture stays as it was rather than flickering.
    public func image(in extent: CGRect) -> CIImage {
        let image: CIImage? = switch self {
        case .linear(let mask): Self.render(mask, in: extent)
        case .radial(let mask): Self.render(mask, in: extent)
        case .brush(let mask): mask.image(in: extent)
        case .detected(let mask): Self.render(mask, in: extent)
        }
        return (image ?? CIImage(color: .black)).cropped(to: extent)
    }

    /// Whatever was found, stretched to the frame it is asked for: a raster is a soft thing,
    /// like a painted mask, and it is computed at whatever size Vision was given.
    private static func render(_ mask: DetectedMask, in extent: CGRect) -> CIImage? {
        let (added, removed) = mask.addedAndRemoved
        // Nothing found and nothing painted: black, so the layer changes nothing. Something
        // painted is worth showing even before the answer comes.
        var found = MaskRasterStore.shared.raster(for: mask.id).flatMap { stretched($0, to: extent) }
        if found == nil, added == nil { return nil }

        if let added = added?.image(in: extent) {
            found = larger(of: added, and: found ?? CIImage(color: .black).cropped(to: extent))
        }
        if let removed = removed?.image(in: extent), let current = found {
            // Out of what is there: the painted part, taken away.
            let invert = CIFilter.colorInvert()
            invert.inputImage = removed
            let keep = CIFilter.multiplyCompositing()
            keep.inputImage = current
            keep.backgroundImage = invert.outputImage
            found = keep.outputImage
        }
        guard let combined = found?.cropped(to: extent) else { return nil }
        guard mask.isInverted else { return combined }
        let invert = CIFilter.colorInvert()
        invert.inputImage = combined
        return invert.outputImage
    }

    /// What was found, stretched to the frame asked for, black outside it.
    private static func stretched(_ raster: CIImage, to extent: CGRect) -> CIImage? {
        let source = raster.extent
        guard source.width > 0, source.height > 0 else { return nil }
        return raster
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / source.width, y: extent.height / source.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .composited(over: CIImage(color: .black))
    }

    /// The greater of two masks: what either one holds, held by both.
    private static func larger(of first: CIImage, and second: CIImage) -> CIImage? {
        let filter = CIFilter.maximumCompositing()
        filter.inputImage = first
        filter.backgroundImage = second
        return filter.outputImage
    }

    private static func render(_ mask: LinearMask, in extent: CGRect) -> CIImage? {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = mask.start.location(in: extent)
        gradient.point1 = mask.end.location(in: extent)
        gradient.color0 = .white
        gradient.color1 = .black
        return gradient.outputImage
    }

    /// The most the circle is drawn at, in pixels. A soft gradient loses nothing to being
    /// enlarged, and a bounded source keeps the render bounded.
    private static let largestDrawnRadius: CGFloat = 2048

    private static func render(_ mask: RadialMask, in extent: CGRect) -> CIImage? {
        // Gradients are only circular: a circle is drawn, then squeezed into the ellipse.
        // Drawn at the size of the ellipse and cut to its own bounds first. It once was drawn
        // 1000 px wide whatever the mask: an infinite image that Core Image rendered large
        // before reducing it, so that a disc of a few pixels cost tens of gigabytes.
        let (radiusX, radiusY) = (max(mask.radiusX * extent.width, 0.5), max(mask.radiusY * extent.height, 0.5))
        let unit = min(max(radiusX, radiusY), Self.largestDrawnRadius)
        let bounds = CGRect(x: -unit - 1, y: -unit - 1, width: 2 * unit + 2, height: 2 * unit + 2)
        let gradient = CIFilter.radialGradient()
        gradient.center = .zero
        gradient.radius0 = Float(unit * (1 - min(max(mask.feather, 0), 1)))
        gradient.radius1 = Float(unit)
        gradient.color0 = .white
        gradient.color1 = .black
        let center = mask.center.location(in: extent)
        let ellipse = gradient.outputImage?
            .cropped(to: bounds)
            .transformed(by: CGAffineTransform(scaleX: radiusX / unit, y: radiusY / unit))
            .transformed(by: CGAffineTransform(translationX: center.x, y: center.y))
            // Black beyond its bounds, as the gradient was before being cut.
            .composited(over: CIImage(color: .black))
        guard mask.isInverted else { return ellipse }
        let invert = CIFilter.colorInvert()
        invert.inputImage = ellipse
        return invert.outputImage
    }
}

extension Mask: Codable {
    private enum CodingKeys: String, CodingKey { case linear, radial, brush, detected }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let mask = try container.decodeIfPresent(LinearMask.self, forKey: .linear) {
            self = .linear(mask)
        } else if let mask = try container.decodeIfPresent(RadialMask.self, forKey: .radial) {
            self = .radial(mask)
        } else if let mask = try container.decodeIfPresent(DetectedMask.self, forKey: .detected) {
            self = .detected(mask)
        } else {
            self = .brush(try container.decode(BrushMask.self, forKey: .brush))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear(let mask): try container.encode(mask, forKey: .linear)
        case .radial(let mask): try container.encode(mask, forKey: .radial)
        case .brush(let mask): try container.encode(mask, forKey: .brush)
        // What was asked for, never the pixels: those are found again and cached.
        case .detected(let mask): try container.encode(mask, forKey: .detected)
        }
    }
}
