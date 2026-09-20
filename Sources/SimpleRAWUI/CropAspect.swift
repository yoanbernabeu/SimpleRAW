import CoreGraphics
import RawEngine

/// Aspect ratios offered by the crop tool.
public enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free = "Free"
    case original = "Original"
    case square = "1:1"
    case threeByTwo = "3:2"
    case fourByThree = "4:3"
    case fiveByFour = "5:4"
    case sevenByFive = "7:5"
    case sixteenByNine = "16:9"

    public var id: Self { self }

    /// Long side over short side, in pixels. `nil` when the ratio is not fixed.
    private var pixelRatio: Double? {
        switch self {
        case .free, .original: nil
        case .square: 1
        case .threeByTwo: 3.0 / 2
        case .fourByThree: 4.0 / 3
        case .fiveByFour: 5.0 / 4
        case .sevenByFive: 7.0 / 5
        case .sixteenByNine: 16.0 / 9
        }
    }

    /// Width / height to hold while cropping, in the normalized units of `CropRect`, where
    /// the whole frame is 1 × 1 whatever its shape. Ratios follow the frame's orientation:
    /// 16:9 on a portrait frame means 9:16. `turned` goes against it: a vertical 4:5 out of a
    /// horizontal shot.
    public func normalizedAspect(in frame: CGSize, turned: Bool = false) -> Double? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        if self == .original { return 1 }  // The frame's own shape: turning it means nothing.
        guard let pixelRatio else { return nil }
        let isLandscape = (frame.width >= frame.height) != turned
        let oriented = isLandscape ? pixelRatio : 1 / pixelRatio
        return oriented / (frame.width / frame.height)
    }
}
