import CoreImage
import CoreImage.CIFilterBuiltins
import simd

extension CIImage {
    /// Red, green and blue multiplied by `factor`, then shifted by `bias`; alpha is left
    /// alone. What fading a mask, lifting a veil or darkening corners all come down to.
    func scalingRGB(by factor: Double, bias: Double = 0) -> CIImage {
        guard factor != 1 || bias != 0 else { return self }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = self
        filter.rVector = CIVector(x: factor, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: factor, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: factor, w: 0)
        filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        return filter.outputImage ?? self
    }
}

/// How bright a color looks: the luminance weights of Rec. 709, the primaries of sRGB. The
/// one place they are written in the engine.
enum Rec709 {
    private static let (red, green, blue) = (0.2126, 0.7152, 0.0722)

    static let weights = SIMD3<Float>(Float(red), Float(green), Float(blue))
    /// The same, as the row of a color matrix.
    ///
    /// `nonisolated(unsafe)` because a `CIVector` is not marked `Sendable` in every SDK this
    /// builds against, and one shared here would be an error on the older of them. It is a
    /// constant that nothing can change: the class is immutable, and this is a `let` read by
    /// filters and never written.
    nonisolated(unsafe) static let vector = CIVector(x: red, y: green, z: blue, w: 0)

    static func luma(_ rgb: SIMD3<Float>) -> Float {
        (rgb * weights).sum()
    }
}
