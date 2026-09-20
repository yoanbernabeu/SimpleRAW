import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// What turns a file into the image the pipeline starts from. A RAW file and a rendered one
/// (JPEG, HEIC, TIFF, PNG) are decoded differently; everything after is the same.
protocol PhotoDecoder: AnyObject {
    var info: RawInfo { get }
    /// The file's metadata, carried over to exports.
    var properties: [String: Any] { get }
    /// - Parameter scaleFactor: below 1 for a fast preview at reduced resolution.
    func decoded(_ adjustments: Adjustments, scaleFactor: Float) -> CIImage?
    /// The camera's own rendering of the picture, if the file embeds one.
    var embeddedPreview: CIImage? { get }
    func whiteBalance(neutralAt point: NormalizedPoint) -> WhiteBalance?
}

/// RAW files, through `CIRAWFilter`: exposure, white balance, noise, sharpness and lens
/// correction happen on the sensor data.
final class RawDecoder: PhotoDecoder {
    let info: RawInfo
    private let filter: CIRAWFilter

    /// `nil` when the file is not a RAW file this Mac can decode.
    init?(url: URL) {
        // CIRAWFilter happily returns a filter, and even an output image, for a file it cannot
        // decode. A missing sensor size is the reliable sign that nothing was decoded.
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize.width > 0 else { return nil }
        self.filter = filter
        info = RawInfo(filter)

        // CIRAWFilter uses its own per-camera baseline and ignores the file's. Cameras that
        // underexpose the raw data to protect highlights (Ricoh's highlight correction) say so
        // in this tag: without it, those shots come out a full stop too dark.
        if let baselineExposure = info.baselineExposure {
            filter.baselineExposure = Float(baselineExposure)
        }
    }

    var properties: [String: Any] { filter.properties as? [String: Any] ?? [:] }

    func decoded(_ adjustments: Adjustments, scaleFactor: Float) -> CIImage? {
        configure(adjustments, scaleFactor: scaleFactor)
        return filter.outputImage
    }

    /// Unlike the decoded image, the preview comes as stored: sensor orientation.
    var embeddedPreview: CIImage? { filter.previewImage?.oriented(filter.orientation) }

    /// The decoder works it out from the sensor data; its own settings are left as they were.
    func whiteBalance(neutralAt point: NormalizedPoint) -> WhiteBalance? {
        let (temperature, tint, scale) = (filter.neutralTemperature, filter.neutralTint, filter.scaleFactor)
        defer {
            filter.scaleFactor = scale
            filter.neutralTemperature = temperature
            filter.neutralTint = tint
        }
        // The location is in the coordinates of the full-size output (origin bottom-left).
        filter.scaleFactor = 1
        filter.neutralLocation = point.location(in: CGRect(origin: .zero, size: info.imageSize))
        let picked = WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
        return picked.temperature.isFinite && picked.tint.isFinite ? picked : nil
    }

    private func configure(_ adjustments: Adjustments, scaleFactor: Float) {
        filter.scaleFactor = scaleFactor
        filter.exposure = Float(adjustments.exposure)

        let whiteBalance = adjustments.whiteBalance(orAsShot: info.asShotWhiteBalance)
        filter.neutralTemperature = Float(whiteBalance.temperature)
        filter.neutralTint = Float(whiteBalance.tint)

        let defaults = info.decoderDefaults
        if info.capabilities.sharpness {
            filter.sharpnessAmount = amount(adjustments.sharpness ?? defaults.sharpness)
        }
        if info.capabilities.luminanceNoiseReduction {
            filter.luminanceNoiseReductionAmount = amount(adjustments.luminanceNoiseReduction ?? defaults.luminanceNoiseReduction)
        }
        if info.capabilities.colorNoiseReduction {
            filter.colorNoiseReductionAmount = amount(adjustments.colorNoiseReduction ?? defaults.colorNoiseReduction)
        }
        if info.capabilities.lensCorrection {
            filter.isLensCorrectionEnabled = adjustments.lensCorrection
        }
    }

    private func amount(_ slider: Double) -> Float {
        Float(Slider.unipolar(slider))
    }
}

/// Rendered files: JPEG, HEIC, TIFF, PNG. There is no sensor data to go back to, so exposure
/// and white balance are applied to the picture as it is, and what only a RAW decoder can do
/// (its sharpening, its noise reduction, the eyedropper) is reported as unavailable.
final class RenderedDecoder: PhotoDecoder {
    /// What "as shot" means for a picture that is already rendered.
    static let neutralWhiteBalance = WhiteBalance(temperature: 6500, tint: 0)

    let info: RawInfo
    let properties: [String: Any]
    private let image: CIImage

    /// `nil` when the file is not a picture.
    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        self.image = image
        properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        info = RawInfo(renderedImageSize: image.extent.size, properties: properties)
    }

    func decoded(_ adjustments: Adjustments, scaleFactor: Float) -> CIImage? {
        var output = image
        if scaleFactor < 1 {
            output = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scaleFactor), y: CGFloat(scaleFactor)))
        }
        if adjustments.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = output
            exposure.ev = Float(adjustments.exposure)
            output = exposure.outputImage ?? output
        }
        if let whiteBalance = adjustments.whiteBalance, whiteBalance != Self.neutralWhiteBalance {
            // Declaring the light bluer than it was makes the filter warm the picture up.
            let shift = CIFilter.temperatureAndTint()
            shift.inputImage = output
            shift.neutral = CIVector(x: whiteBalance.temperature, y: whiteBalance.tint)
            shift.targetNeutral = CIVector(x: Self.neutralWhiteBalance.temperature, y: Self.neutralWhiteBalance.tint)
            output = shift.outputImage ?? output
        }
        return output
    }

    var embeddedPreview: CIImage? { nil }

    func whiteBalance(neutralAt point: NormalizedPoint) -> WhiteBalance? { nil }
}
