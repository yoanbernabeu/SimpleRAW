import CoreGraphics
import RawEngine

/// Where the image sits in the canvas. Shared by the Metal view, which draws it there, and by
/// the crop overlay, which must line up with it to the pixel.
enum FitGeometry {
    /// Breathing room around the image, in points.
    static let padding: CGFloat = 16

    /// The largest centered rectangle of the given width / height ratio inside `size`, once
    /// `padding` is set aside. Works in whatever unit `size` and `padding` are in.
    static func frame(forAspect aspect: CGFloat, in size: CGSize, padding: CGFloat) -> CGRect {
        let available = CGSize(width: size.width - 2 * padding, height: size.height - 2 * padding)
        guard available.width > 0, available.height > 0, aspect > 0 else { return .zero }
        let width = min(available.width, available.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// A crop, in view coordinates. Both have their origin at the top-left.
    static func rect(of crop: CropRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + crop.x * frame.width,
            y: frame.minY + crop.y * frame.height,
            width: crop.width * frame.width,
            height: crop.height * frame.height
        )
    }

    static func normalized(_ location: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (location.x - frame.minX) / frame.width, y: (location.y - frame.minY) / frame.height)
    }
}
