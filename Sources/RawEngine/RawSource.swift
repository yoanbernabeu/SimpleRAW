import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// An opened photo, ready to be developed as many times as needed. RAW files first of all,
/// and rendered ones too (JPEG, HEIC, TIFF, PNG): a photo library is not made of RAW only.
///
/// `RawSource` picks the decoder; everything after decoding belongs to the `DevelopPipeline`
/// and is the same for every format.
public final class RawSource {
    public let url: URL
    public var info: RawInfo { decoder.info }

    private let decoder: any PhotoDecoder
    private let pipeline: DevelopPipeline

    /// No photo weighs a gigabyte; a file that does is something else, or means harm.
    public static let maximumFileSize = 1_073_741_824

    /// - Parameter maximumSize: in bytes; for tests.
    public init(url: URL, pipeline: DevelopPipeline = .standard, maximumSize: Int = RawSource.maximumFileSize) throws {
        // Decoders of RAW formats are complex, and have been attacked: they are only handed
        // what is a file (a link to one is one), of a size that makes sense. Both are read
        // from the file system, before a byte of the file is.
        let file = url.resolvingSymlinksInPath()
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let values else { throw RawEngineError.unsupportedFile(url) }
        guard values.isRegularFile == true else { throw RawEngineError.notARegularFile(url) }
        guard let size = values.fileSize, size > 0 else { throw RawEngineError.unsupportedFile(url) }
        guard size <= maximumSize else { throw RawEngineError.fileTooLarge(url, limit: maximumSize) }

        // Chosen on the type of the file, not on who accepts it: CIRAWFilter also opens JPEG,
        // TIFF, PNG and HEIC files, which is undocumented, and would then decide alone what
        // exposure or white balance mean for them. The other decoder is a fallback for a file
        // whose extension lies.
        let isRaw = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .rawImage) ?? false
        let raw: () -> (any PhotoDecoder)? = { RawDecoder(url: url) }
        let rendered: () -> (any PhotoDecoder)? = { RenderedDecoder(url: url) }
        guard let decoder = isRaw ? (raw() ?? rendered()) : (rendered() ?? raw()) else {
            throw RawEngineError.unsupportedFile(url)
        }
        self.url = url
        self.decoder = decoder
        self.pipeline = pipeline
    }

    /// The developed image. Nothing is computed here: rendering happens on export or display.
    /// - Parameter scaleFactor: below 1 for a fast preview decoded at reduced resolution.
    public func image(adjustments: Adjustments = Adjustments(), scaleFactor: Float = 1) throws -> CIImage {
        guard let decoded = decoder.decoded(adjustments, scaleFactor: scaleFactor) else {
            throw RawEngineError.unsupportedFile(url)
        }
        return pipeline.apply(adjustments, to: decoded).settingProperties(exportProperties())
    }

    /// The JPEG embedded by the camera: a rendering reference.
    public func embeddedPreview() throws -> CIImage {
        guard let preview = decoder.embeddedPreview else { throw RawEngineError.noEmbeddedPreview(url) }
        return preview
    }

    /// The white balance that makes the surface at `point` neutral: what the eyedropper picks.
    /// `nil` outside of the picture, and for formats that have no sensor data to work it from.
    public func whiteBalance(neutralAt point: NormalizedPoint) -> WhiteBalance? {
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return decoder.whiteBalance(neutralAt: point)
    }

    /// Metadata to carry over to the export. The decoded image is already upright, so the
    /// original orientation must be reset, otherwise viewers rotate it a second time.
    private func exportProperties() -> [String: Any] {
        var properties = decoder.properties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return properties
    }
}
