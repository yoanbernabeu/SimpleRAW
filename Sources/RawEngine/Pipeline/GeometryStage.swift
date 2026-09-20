import CoreImage
import CoreImage.CIFilterBuiltins

/// Quarter turns, straightening and crop. Runs last: every other stage, vignetting above all,
/// is defined on the uncropped frame. The keystone correction is `Geometry`'s too, but it is
/// applied early, by `LensCorrectionStage`, which says why.
public struct GeometryStage: PipelineStage {
    public init() {}

    public func apply(_ adjustments: Adjustments, to image: CIImage) -> CIImage {
        let geometry = adjustments.geometry
        guard !geometry.isNeutral, !image.extent.isInfinite else { return image }

        var output = Self.turned(image, clockwiseQuarterTurns: geometry.quarterTurns)
        output = Self.straightened(output, by: geometry.straighten)
        if let crop = geometry.crop {
            output = Self.cropped(output, to: crop)
        }
        return Self.atOrigin(output)
    }

    private static func turned(_ image: CIImage, clockwiseQuarterTurns turns: Int) -> CIImage {
        switch turns {
        case 1: atOrigin(image.oriented(.right))
        case 2: atOrigin(image.oriented(.down))
        case 3: atOrigin(image.oriented(.left))
        default: image
        }
    }

    private static func straightened(_ image: CIImage, by degrees: Double) -> CIImage {
        guard degrees != 0 else { return image }
        let extent = image.extent
        let frame = Geometry.inscribedSize(in: extent.size, straightenedBy: degrees)
        // Core Image angles are counter-clockwise; ours are clockwise as seen on screen.
        let rotation = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
        let inner = CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
        return image.transformed(by: rotation).cropped(to: integral(inner))
    }

    private static func cropped(_ image: CIImage, to crop: CropRect) -> CIImage {
        let extent = image.extent
        // `CropRect` has its origin at the top-left; Core Image at the bottom-left.
        let rect = CGRect(
            x: extent.minX + crop.x * extent.width,
            y: extent.minY + (1 - crop.maxY) * extent.height,
            width: crop.width * extent.width,
            height: crop.height * extent.height
        )
        return image.cropped(to: integral(rect))
    }

    private static func integral(_ rect: CGRect) -> CGRect { Geometry.integral(rect) }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
