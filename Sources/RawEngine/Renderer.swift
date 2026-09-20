import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

public struct ExportOptions: Codable, Equatable, Sendable {
    public enum ColorSpace: String, Codable, Sendable, CaseIterable {
        case sRGB = "srgb"
        case displayP3 = "p3"

        var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
            }
        }
    }

    public enum Format: String, Codable, Sendable, CaseIterable {
        case jpeg
        /// 16 bits per channel: what a print lab or another editor should be handed.
        case tiff16
        case png
        case heic

        public var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .tiff16: "tif"
            case .png: "png"
            case .heic: "heic"
            }
        }
    }

    /// Sharpening applied after resizing: downscaling softens, and so does paper.
    public enum Sharpening: String, Codable, Sendable, CaseIterable {
        case none, low, standard, high

        var amount: Float {
            switch self {
            case .none: 0
            case .low: 0.25
            case .standard: 0.5
            case .high: 0.9
            }
        }
    }

    /// How much of what the camera wrote goes into the exported file.
    public enum Metadata: String, Codable, Sendable, CaseIterable {
        case all
        /// Without where the picture was taken, nor with whose camera: no GPS, no place name,
        /// no maker notes, no serial number, no owner name. What a picture made for the web
        /// should carry.
        case withoutLocation
        /// The author and the copyright, nothing else.
        case copyrightOnly
    }

    public var format: Format = .jpeg
    /// Quality of lossy formats (JPEG, HEIC), from 0 to 1.
    public var quality: Double = 0.92
    /// Long edge size in pixels. `nil` = full resolution.
    public var longEdge: Int?
    public var colorSpace: ColorSpace = .sRGB
    public var sharpening: Sharpening = .none
    /// Written in the file's metadata. `nil` = nothing added.
    public var copyright: String?
    public var author: String?
    public var metadata: Metadata = .all

    public init() {}

    /// Presets written before a field existed still open.
    public init(from decoder: Decoder) throws {
        let neutral = ExportOptions()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? neutral.format
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? neutral.quality
        longEdge = try c.decodeIfPresent(Int.self, forKey: .longEdge)
        colorSpace = try c.decodeIfPresent(ColorSpace.self, forKey: .colorSpace) ?? neutral.colorSpace
        sharpening = try c.decodeIfPresent(Sharpening.self, forKey: .sharpening) ?? neutral.sharpening
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        metadata = try c.decodeIfPresent(Metadata.self, forKey: .metadata) ?? neutral.metadata
        self = sanitized()
    }

    /// Smallest long edge that still is a picture.
    static let minimumLongEdge = 16

    /// A quality an encoder accepts, and a size that means something: else full size.
    public func sanitized() -> ExportOptions {
        var result = self
        result.quality = quality.bounded(to: 0.05...1, else: ExportOptions().quality)
        if let longEdge, longEdge < Self.minimumLongEdge { result.longEdge = nil }
        return result
    }
}

/// Owns the GPU context that renders in the background: exports, batches and thumbnails.
/// Expensive to create, so there is one, `Renderer.shared`.
///
/// `@unchecked Sendable`: all it holds is a `CIContext`, which is immutable and documented as
/// safe to share between threads.
public final class Renderer: @unchecked Sendable {
    /// The one to use. Thumbnails, a batch and an export may all go through it at once.
    public static let shared = Renderer()

    private let context: CIContext

    public init() {
        context = CIContext(options: [
            // Half floats: no banding as stages pile up.
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            // Background work gives way to the canvas, which shares the GPU with it.
            .priorityRequestLow: true,
        ])
    }

    public func writeJPEG(_ image: CIImage, to url: URL, options: ExportOptions = ExportOptions()) throws {
        var jpeg = options
        jpeg.format = .jpeg
        try write(image, to: url, options: jpeg)
    }

    /// Resizes, sharpens, signs and writes the picture in the format the options ask for.
    /// - Parameter credits: what this one photo says about itself — title, caption, author,
    ///   copyright, keywords. They belong to one picture, not to an export preset, which is
    ///   why they are not part of `options`.
    public func write(_ image: CIImage, to url: URL, options: ExportOptions = ExportOptions(), credits: PhotoCredits = PhotoCredits()) throws {
        // Options built in code (a command line) get the same bounds as decoded ones.
        let options = options.sanitized()
        let output = Self.prepared(image, options: options, credits: credits)
        let colorSpace = options.colorSpace.cgColorSpace
        let quality = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): options.quality]
        do {
            switch options.format {
            case .jpeg: try context.writeJPEGRepresentation(of: output, to: url, colorSpace: colorSpace, options: quality)
            case .heic: try context.writeHEIFRepresentation(of: output, to: url, format: .RGBA8, colorSpace: colorSpace, options: quality)
            case .png: try context.writePNGRepresentation(of: output, to: url, format: .RGBA8, colorSpace: colorSpace)
            case .tiff16: try context.writeTIFFRepresentation(of: output, to: url, format: .RGBA16, colorSpace: colorSpace)
            }
        } catch {
            throw RawEngineError.exportFailed(url, underlying: error.localizedDescription)
        }
        // A full-size export leaves hundreds of megabytes of intermediates behind: given back
        // at once, rather than kept for a next export that may never come.
        if options.longEdge == nil { context.clearCaches() }
    }

    /// The picture as it will be written: resized, then sharpened for its new size, with the
    /// author's name and copyright added to its metadata.
    static func prepared(_ image: CIImage, options: ExportOptions, credits: PhotoCredits = PhotoCredits()) -> CIImage {
        var output = resized(image, longEdge: options.longEdge)
        if options.sharpening != .none {
            // On display-referred values, like every sharpening in the app: no halo.
            let encode = CIFilter.linearToSRGBToneCurve()
            encode.inputImage = output.clampedToExtent()
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = encode.outputImage
            sharpen.radius = 1.2
            sharpen.sharpness = options.sharpening.amount
            let decode = CIFilter.sRGBToneCurveToLinear()
            decode.inputImage = sharpen.outputImage
            output = (decode.outputImage ?? output).cropped(to: output.extent).settingProperties(output.properties)
        }
        return output.settingProperties(signed(output.properties, options: options, credits: credits))
    }

    private static func signed(_ properties: [String: Any], options: ExportOptions, credits: PhotoCredits) -> [String: Any] {
        var properties = ExportMetadata.kept(properties, options.metadata)
        var iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        // What the photo says about itself beats what the preset says about the batch.
        if let copyright = credits.copyright ?? PhotoCredits.nonBlank(options.copyright) {
            iptc[kCGImagePropertyIPTCCopyrightNotice as String] = copyright
            tiff[kCGImagePropertyTIFFCopyright as String] = copyright
        }
        if let author = credits.author ?? PhotoCredits.nonBlank(options.author) {
            iptc[kCGImagePropertyIPTCByline as String] = [author]
            tiff[kCGImagePropertyTIFFArtist as String] = author
        }
        // The title, the caption and the keywords are the photographer's own work, not the
        // camera's: they are written whatever is kept of the rest.
        if let title = credits.title { iptc[kCGImagePropertyIPTCObjectName as String] = title }
        if let caption = credits.caption {
            iptc[kCGImagePropertyIPTCCaptionAbstract as String] = caption
            tiff[kCGImagePropertyTIFFImageDescription as String] = caption
        }
        let written = credits.writtenKeywords
        if !written.isEmpty { iptc[kCGImagePropertyIPTCKeywords as String] = written }
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary as String] = iptc }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary as String] = tiff }
        return properties
    }

    /// Only ever downscales: an image smaller than `longEdge` is left as is.
    static func resized(_ image: CIImage, longEdge: Int?) -> CIImage {
        guard let longEdge else { return image }
        let current = max(image.extent.width, image.extent.height)
        guard current > CGFloat(longEdge) else { return image }

        let stage = CIFilter.lanczosScaleTransform()
        stage.inputImage = image
        stage.scale = Float(CGFloat(longEdge) / current)
        guard let scaled = stage.outputImage else { return image }
        // The resulting extent is not necessarily integral: crop inward so that no
        // transparent fringe gets exported.
        let extent = scaled.extent
        let origin = CGPoint(x: extent.minX.rounded(.up), y: extent.minY.rounded(.up))
        let inner = CGRect(
            x: origin.x,
            y: origin.y,
            width: extent.maxX.rounded(.down) - origin.x,
            height: extent.maxY.rounded(.down) - origin.y
        )
        return scaled.cropped(to: inner).settingProperties(image.properties)
    }
}
