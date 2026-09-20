import CoreImage
import ImageIO

/// What the engine knows about a RAW file before any development.
public struct RawInfo: Sendable {
    public let make: String?
    public let model: String?
    public let lens: String?
    /// Sensor dimensions, before orientation.
    public let nativeSize: CGSize
    /// Full-resolution size of the developed, upright image.
    public let imageSize: CGSize
    public let iso: Int?
    public let exposureTime: Double?
    public let aperture: Double?
    public let focalLength: Double?
    /// When the picture was taken. EXIF writes local time with no zone: it is read as if UTC,
    /// like every date of the catalog, so that a photo taken at 11:14 says 11:14 anywhere.
    public var captureDate: Date? { captureDateText.flatMap(Self.date(fromExif:)) }
    /// The same as the camera wrote it: "2026:09:11 11:14:40".
    public let captureDateText: String?
    public let asShotWhiteBalance: WhiteBalance
    /// The DNG `BaselineExposure` tag, in EV: how far the camera says the raw data sits from
    /// its intended brightness. `nil` for non-DNG files.
    public let baselineExposure: Double?
    public let decoderVersion: String
    /// `false` for rendered files (JPEG, HEIC, TIFF, PNG), which the same pipeline develops.
    public let isRaw: Bool
    public let capabilities: Capabilities
    public let decoderDefaults: DecoderDefaults

    public struct Capabilities: Sendable {
        public let sharpness: Bool
        public let luminanceNoiseReduction: Bool
        public let colorNoiseReduction: Bool
        public let lensCorrection: Bool
    }

    /// Amounts the decoder picked for this file, on the slider scale (0 to 100). They apply
    /// whenever the matching `Adjustments` field is `nil`.
    public struct DecoderDefaults: Sendable {
        public let sharpness: Double
        public let luminanceNoiseReduction: Double
        public let colorNoiseReduction: Double

        public init(sharpness: Double, luminanceNoiseReduction: Double, colorNoiseReduction: Double) {
            self.sharpness = sharpness
            self.luminanceNoiseReduction = luminanceNoiseReduction
            self.colorNoiseReduction = colorNoiseReduction
        }
    }

    /// A rendered file: no sensor data, so nothing that only a RAW decoder can do.
    init(renderedImageSize size: CGSize, properties: [String: Any]) {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmed
        model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmed
        lens = (exif[kCGImagePropertyExifLensModel as String] as? String)?.trimmed
        nativeSize = size
        imageSize = size
        iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
        aperture = exif[kCGImagePropertyExifFNumber as String] as? Double
        focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double
        captureDateText = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        asShotWhiteBalance = RenderedDecoder.neutralWhiteBalance
        baselineExposure = nil
        decoderVersion = "rendered"
        isRaw = false
        capabilities = Capabilities(sharpness: false, luminanceNoiseReduction: false, colorNoiseReduction: false, lensCorrection: false)
        decoderDefaults = DecoderDefaults(sharpness: 0, luminanceNoiseReduction: 0, colorNoiseReduction: 0)
    }

    init(_ filter: CIRAWFilter) {
        let properties = filter.properties as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any] ?? [:]

        make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmed
        model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmed
        lens = (exif[kCGImagePropertyExifLensModel as String] as? String)?.trimmed
        nativeSize = filter.nativeSize
        // Orientations 5 to 8 are the quarter turns: width and height swap.
        imageSize = filter.orientation.rawValue >= 5
            ? CGSize(width: filter.nativeSize.height, height: filter.nativeSize.width)
            : filter.nativeSize
        iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
        exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
        aperture = exif[kCGImagePropertyExifFNumber as String] as? Double
        focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double
        captureDateText = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        asShotWhiteBalance = WhiteBalance(
            temperature: Double(filter.neutralTemperature),
            tint: Double(filter.neutralTint)
        )
        baselineExposure = dng[kCGImagePropertyDNGBaselineExposure as String] as? Double
        decoderVersion = filter.decoderVersion.rawValue
        isRaw = true
        capabilities = Capabilities(
            sharpness: filter.isSharpnessSupported,
            luminanceNoiseReduction: filter.isLuminanceNoiseReductionSupported,
            colorNoiseReduction: filter.isColorNoiseReductionSupported,
            lensCorrection: filter.isLensCorrectionSupported
        )
        decoderDefaults = DecoderDefaults(
            sharpness: Double(filter.sharpnessAmount) * 100,
            luminanceNoiseReduction: Double(filter.luminanceNoiseReductionAmount) * 100,
            colorNoiseReduction: Double(filter.colorNoiseReductionAmount) * 100
        )
    }
}

extension RawInfo {
    /// `nil` for what is not a date: cameras with no clock set write zeros.
    static func date(fromExif text: String) -> Date? {
        // A formatter is not Sendable, and cheap enough to make for the one date of a photo.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        return formatter.date(from: text)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
