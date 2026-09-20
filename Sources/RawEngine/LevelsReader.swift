import CoreImage
import CoreImage.CIFilterBuiltins

/// Reads how the levels of a picture are distributed, on the GPU. The one place where that
/// is done: the histogram and Auto must agree on what they see, and they share one context.
///
/// Levels are display-referred (sRGB-encoded), which is what a photographer expects to read:
/// mid-gray sits in the middle. Out-of-range values (extended range highlights, negative
/// shadows) fall in the end bins, where clipping is read.
final class LevelsReader: @unchecked Sendable {
    static let binCount = 256
    static let shared = LevelsReader()

    /// Immutable, and documented as safe to share between threads, like every `CIContext`:
    /// that is all this class holds, hence `@unchecked Sendable`.
    let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    /// The picture as it is displayed, clamped to the display range.
    static func displayed(_ image: CIImage) throws -> CIImage {
        guard !image.extent.isInfinite, !image.extent.isEmpty else { throw RawEngineError.analysisFailed }
        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = image
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = encode.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let output = clamp.outputImage else { throw RawEngineError.analysisFailed }
        return output
    }

    /// Per channel (red, green, blue), the share of pixels falling in each bin.
    func levels(of image: CIImage) throws -> [[Float]] {
        try levels(ofDisplayed: Self.displayed(image), extent: image.extent)
    }

    /// Same, for a picture that is display-referred already.
    func levels(ofDisplayed image: CIImage, extent: CGRect) throws -> [[Float]] {
        guard !extent.isInfinite, !extent.isEmpty else { throw RawEngineError.analysisFailed }
        let area = CIFilter.areaHistogram()
        area.inputImage = image
        area.extent = extent
        area.count = Self.binCount
        area.scale = 1
        guard let output = area.outputImage else { throw RawEngineError.analysisFailed }

        var bins = [Float](repeating: 0, count: Self.binCount * 4)
        context.render(
            output,
            toBitmap: &bins,
            rowBytes: Self.binCount * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: Self.binCount, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        return (0..<3).map { channel in
            let counts = (0..<Self.binCount).map { bins[$0 * 4 + channel] }
            let total = counts.reduce(0, +)
            return counts.map { total > 0 ? $0 / total : 0 }
        }
    }
}
