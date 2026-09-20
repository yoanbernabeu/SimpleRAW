import Foundation

/// Named export settings: size, quality, color space, and how to name the files.
public struct ExportPreset: Codable, Equatable, Sendable, Identifiable, StoredItem {
    public var name: String
    public var options = ExportOptions()
    /// `{name}` stands for the name of the source file, without its extension.
    public var fileNameTemplate = "{name}"

    public var id: String { name }

    public init(name: String) {
        self.name = name
    }

    /// Room kept in a file name for the "-12" of a name already taken.
    private static let numberRoom = 4

    /// The template is text from a JSON file that photographers pass around: what it gives is
    /// made a plain file name, whatever it holds. Nothing left of it: the name of the source.
    public func fileName(for source: URL) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = options.format.fileExtension
        let wanted = fileNameTemplate.replacingOccurrences(of: "{name}", with: stem)
        return FileName.sanitized(wanted, fallback: stem, reserving: ext.utf8.count + 1 + Self.numberRoom) + "." + ext
    }

    /// Where the export of `source` goes in `directory`: never over a file that is there, and
    /// never anywhere else.
    public func destination(for source: URL, in directory: URL) -> URL {
        let wanted = directory.appendingPathComponent(fileName(for: source))
        // Cannot happen with a sanitized name; checked all the same, where the file is written.
        let contained = FileName.isContained(wanted, in: directory)
            ? wanted
            : directory.appendingPathComponent(FileName.lastResort).appendingPathExtension(options.format.fileExtension)
        return FileName.free(contained)
    }

    /// See `FileName.free(_:)`.
    public static func freeDestination(_ wanted: URL) -> URL {
        FileName.free(wanted)
    }

    public static let builtIns: [ExportPreset] = [
        ExportPreset(name: "Full size"),
        print,
        make("Web 2048", longEdge: 2048, quality: 0.85, suffix: "-web"),
        make("Small 1080", longEdge: 1080, quality: 0.8, suffix: "-small"),
    ]

    /// For a lab or another editor: nothing thrown away.
    private static let print: ExportPreset = {
        var preset = ExportPreset(name: "Print (TIFF 16-bit)")
        preset.options.format = .tiff16
        preset.options.colorSpace = .displayP3
        preset.options.sharpening = .low
        return preset
    }()

    private static func make(_ name: String, longEdge: Int, quality: Double, suffix: String) -> ExportPreset {
        var preset = ExportPreset(name: name)
        preset.options.longEdge = longEdge
        preset.options.quality = quality
        // Downscaling softens: screen-size exports get some of it back.
        preset.options.sharpening = .standard
        // Made to be published: not with the place it was taken at, nor the camera's serial number.
        preset.options.metadata = .withoutLocation
        preset.fileNameTemplate = "{name}" + suffix
        return preset
    }
}
