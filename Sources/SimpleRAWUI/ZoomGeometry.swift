import CoreGraphics

/// What is shown at 100 %: one image pixel per screen pixel, around a focus point.
/// Points are normalized to the image (0...1), rectangles are in image pixels; both have
/// their origin at the top-left.
enum ZoomGeometry {
    /// The part of the image a view of `view` pixels shows, kept inside the image. An image
    /// smaller than the view, in one direction or both, is shown whole in that direction.
    static func visibleRect(of image: CGSize, in view: CGSize, centeredOn center: CGPoint) -> CGRect {
        let size = CGSize(width: min(view.width, image.width), height: min(view.height, image.height))
        let focus = clampedCenter(center, image: image, view: view)
        return CGRect(
            x: (focus.x * image.width - size.width / 2).rounded(),
            y: (focus.y * image.height - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    /// The closest focus point that keeps the visible area inside the image.
    static func clampedCenter(_ center: CGPoint, image: CGSize, view: CGSize) -> CGPoint {
        func clamped(_ value: CGFloat, image: CGFloat, view: CGFloat) -> CGFloat {
            let margin = min(view, image) / 2 / image
            return min(max(value, margin), 1 - margin)
        }
        return CGPoint(
            x: clamped(center.x, image: image.width, view: view.width),
            y: clamped(center.y, image: image.height, view: view.height)
        )
    }

    /// How far the focus moves for a drag of `translation` points. The picture follows the
    /// pointer, so the focus goes the other way.
    static func panDelta(forDrag translation: CGSize, backingScale: CGFloat, image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        return CGSize(
            width: -translation.width * backingScale / image.width,
            height: -translation.height * backingScale / image.height
        )
    }

    /// The point of the picture under `location` when the picture is fitted in a canvas of
    /// `size`, clamped to the picture.
    static func imagePoint(at location: CGPoint, aspect: CGFloat, in size: CGSize, padding: CGFloat) -> CGPoint {
        let frame = FitGeometry.frame(forAspect: aspect, in: size, padding: padding)
        guard !frame.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let point = FitGeometry.normalized(location, in: frame)
        return CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    /// Where the whole picture would sit, in points, in a canvas that shows it at 100 % around
    /// `center`: a frame larger than the canvas. What is positioned in the picture (masks,
    /// spots) is laid out in this frame, the same way it is in the fitted one.
    static func imageFrame(of image: CGSize, centeredOn center: CGPoint, in canvas: CGSize, padding: CGFloat, backingScale: CGFloat) -> CGRect {
        let available = CGSize(width: (canvas.width - 2 * padding) * backingScale, height: (canvas.height - 2 * padding) * backingScale)
        guard image.width > 0, image.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let visible = visibleRect(of: image, in: available, centeredOn: center)
        let shown = FitGeometry.frame(forAspect: visible.width / visible.height, in: canvas, padding: padding)
        let scale = shown.width / visible.width
        return CGRect(
            x: shown.minX - visible.minX * scale,
            y: shown.minY - visible.minY * scale,
            width: image.width * scale,
            height: image.height * scale
        )
    }
}
