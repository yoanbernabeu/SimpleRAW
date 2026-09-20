import CoreImage
import CoreImage.CIFilterBuiltins

/// Measures the average color of an image, in linear sRGB.
public struct PixelProbe {
    public struct Pixel {
        public let r: Float, g: Float, b: Float

        public var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        /// Spread between the strongest and weakest channel: 0 for a gray.
        public var chroma: Float { max(r, g, b) - min(r, g, b) }
    }

    public struct RenderingFailed: Error {}

    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])

    public init() {}

    public func average(of image: CIImage) throws -> Pixel {
        try average(of: image, in: image.extent)
    }

    /// Average over a region, in the image's own coordinates (origin bottom-left).
    public func average(of image: CIImage, in region: CGRect) throws -> Pixel {
        let stage = CIFilter.areaAverage()
        stage.inputImage = image
        stage.extent = region
        guard let output = stage.outputImage else { throw RenderingFailed() }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)
        )
        return Pixel(r: pixel[0], g: pixel[1], b: pixel[2])
    }

    /// Spread of the luminance over a region: 0 for a flat area, more for texture or noise.
    public func standardDeviation(of image: CIImage, in region: CGRect) throws -> Float {
        let (width, height) = (Int(region.width), Int(region.height))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let shifted = image.transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        context.render(
            shifted, toBitmap: &pixels, rowBytes: width * 16,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)
        )
        let luminances = stride(from: 0, to: pixels.count, by: 4).map { 0.2126 * pixels[$0] + 0.7152 * pixels[$0 + 1] + 0.0722 * pixels[$0 + 2] }
        let mean = luminances.reduce(0, +) / Float(luminances.count)
        return (luminances.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(luminances.count)).squareRoot()
    }

    /// Solid color swatch, expressed in linear sRGB.
    public static func swatch(r: CGFloat, g: CGFloat, b: CGFloat, size: CGSize = CGSize(width: 64, height: 64)) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!
        return CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
    }
}
