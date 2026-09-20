import CoreGraphics

/// How much of the sensor resolution an on-screen preview needs. Decoding at a reduced scale
/// is what keeps sliders responsive on a 24 MP file.
public enum PreviewScale {
    /// Floor applied while the view has no size yet.
    static let minimum: Float = 0.05

    /// - Parameters:
    ///   - imageSize: full-resolution size of the upright image, in pixels.
    ///   - viewSize: size of the view the image is fitted in, in pixels.
    public static func factor(for imageSize: CGSize, fitting viewSize: CGSize) -> Float {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let fit = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return min(1, max(minimum, Float(fit)))
    }

    /// How far the wanted scale may drift from the one in hand before it is worth paying for.
    /// A quarter either way: past that the preview is either visibly soft or decoded much
    /// larger than the view can show.
    static let tolerance: Float = 0.25

    /// The scale to decode at now, given the one already in hand.
    ///
    /// `factor` follows the size of what is shown, so a crop, a straightening or a keystone
    /// correction changes it — and changing it decodes the RAW again, some forty milliseconds,
    /// in the middle of a drag. That is the whole of the stutter those tools had: the work
    /// itself fits in the frame budget.
    ///
    /// So a gesture keeps the scale it started with. What is shown is then decoded a little
    /// larger or smaller than perfect for a second, which nobody can see while the picture is
    /// moving, and the right scale is taken up the moment the edit settles. The drift is
    /// bounded, so a slider dragged from end to end still costs a few re-decodes rather than
    /// one per frame — and, unlike rounding the scale to a grid, it does not leave a trail of
    /// decoded pictures behind it, each one holding its own memory.
    public static func held(_ held: Float?, wanting wanted: Float, isSettled: Bool) -> Float {
        guard let held, !isSettled, held > 0 else { return wanted }
        return abs(wanted / held - 1) > tolerance ? wanted : held
    }
}
