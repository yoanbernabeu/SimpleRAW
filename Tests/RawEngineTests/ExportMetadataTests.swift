import CoreImage
import Foundation
import ImageIO
import Testing
import TestSupport
@testable import RawEngine

/// A picture exported for the web must not tell where it was taken, nor with whose camera.
@Suite struct ExportMetadataTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-metadata-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A small finite picture carrying what a camera writes, a place and serial numbers included.
    var picture: CIImage {
        PixelProbe.swatch(r: 0.5, g: 0.3, b: 0.1, size: CGSize(width: 120, height: 80)).settingProperties([
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 48.8584, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 2.2945, kCGImagePropertyGPSLongitudeRef as String: "E",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 2.8,
                kCGImagePropertyExifBodySerialNumber as String: "BODY-0042",
                kCGImagePropertyExifLensSerialNumber as String: "LENS-0042",
                kCGImagePropertyExifCameraOwnerName as String: "Yoan",
            ],
            kCGImagePropertyExifAuxDictionary as String: [kCGImagePropertyExifAuxSerialNumber as String: "AUX-0042"],
            kCGImagePropertyMakerAppleDictionary as String: ["1": 14],
            "{MakerRicoh}": ["Serial": "RICOH-0042"],
            kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCCity as String: "Paris", kCGImagePropertyIPTCCopyrightNotice as String: "© Source"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "GR III", kCGImagePropertyTIFFArtist as String: "Source artist"],
        ])
    }

    private func written(_ metadata: ExportOptions.Metadata, copyright: String? = nil) throws -> [String: Any] {
        var options = ExportOptions()
        options.metadata = metadata
        options.copyright = copyright
        let destination = folder.appendingPathComponent("\(metadata.rawValue).jpg")
        try Renderer.shared.write(picture, to: destination, options: options)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func exif(_ properties: [String: Any]) -> [String: Any] {
        properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    }

    /// Without this, "the place is gone" would prove nothing.
    @Test func everythingIsWrittenWhenAskedFor() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let properties = try written(.all)
        let gps = try #require(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        #expect(abs((gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0) - 48.8584) < 0.001)
        #expect(exif(properties)[kCGImagePropertyExifBodySerialNumber as String] as? String == "BODY-0042")
        #expect(exif(properties)[kCGImagePropertyExifFNumber as String] as? Double == 2.8)
    }

    @Test func withoutLocationThePlaceAndTheSerialNumbersAreGone() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let properties = try written(.withoutLocation)
        #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(properties[kCGImagePropertyExifAuxDictionary as String] == nil)
        #expect(!properties.keys.contains { $0.hasPrefix("{Maker") })
        for key in [kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifCameraOwnerName] {
            #expect(exif(properties)[key as String] == nil, "\(key)")
        }
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        #expect(iptc[kCGImagePropertyIPTCCity as String] == nil)
        // What says how the picture was taken stays.
        #expect(exif(properties)[kCGImagePropertyExifFNumber as String] as? Double == 2.8)
        #expect((properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFModel as String] as? String == "GR III")
    }

    /// Not a byte of it anywhere in the file, whatever dictionary ImageIO reports.
    @Test(arguments: [ExportOptions.Metadata.withoutLocation, .copyrightOnly])
    func noSerialNumberIsLeftInTheBytesOfTheFile(metadata: ExportOptions.Metadata) throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try written(metadata)
        let bytes = try Data(contentsOf: folder.appendingPathComponent("\(metadata.rawValue).jpg"))
        for secret in ["BODY-0042", "LENS-0042", "AUX-0042", "RICOH-0042", "Paris"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret)")
        }
    }

    @Test func copyrightOnlyKeepsWhoMadeThePictureAndNothingElse() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let properties = try written(.copyrightOnly, copyright: "© 2026 Yoan")
        #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(exif(properties)[kCGImagePropertyExifFNumber as String] == nil)
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFModel as String] == nil)
        #expect(tiff[kCGImagePropertyTIFFCopyright as String] as? String == "© 2026 Yoan")
        #expect(tiff[kCGImagePropertyTIFFArtist as String] as? String == "Source artist")
        // Still upright: orientation is not information about anybody.
        #expect(properties[kCGImagePropertyOrientation as String] as? Int ?? 1 == 1)
    }

    /// The pure part, where keys that no encoder writes can be checked too.
    @Test func makerNotesOfEveryBrandAreDropped() {
        var options = ExportOptions()
        options.metadata = .withoutLocation
        let kept = Renderer.prepared(picture, options: options).properties
        #expect(!kept.keys.contains { $0.hasPrefix("{Maker") } && kept[kCGImagePropertyGPSDictionary as String] == nil)
        options.metadata = .all
        #expect(Renderer.prepared(picture, options: options).properties["{MakerRicoh}"] != nil)
    }

    /// Keywords are the photographer's own work: they belong in the file that leaves, and
    /// they are the same list the catalog holds — not a copy kept in an export preset.
    @Test func keywordsAreWrittenIntoTheExportedFile() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("keywords.jpg")
        try Renderer.shared.write(
            picture, to: destination, options: ExportOptions(),
            credits: PhotoCredits(keywords: ["street", "Lille", "  ", "street"])
        )
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        #expect(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] == ["street", "Lille"], "blanks and repeats go")
    }

    /// Even when nothing else of the camera's is kept: the keywords were not the camera's.
    @Test func keywordsSurviveEveryMetadataChoice() {
        for choice in ExportOptions.Metadata.allCases {
            var options = ExportOptions()
            options.metadata = choice
            let written = Renderer.prepared(picture, options: options, credits: PhotoCredits(keywords: ["night"])).properties
            let iptc = written[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
            #expect(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] == ["night"], "\(choice)")
        }
        // No keywords, no empty list in the file.
        let bare = Renderer.prepared(picture, options: ExportOptions(), credits: PhotoCredits()).properties
        let iptc = bare[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        #expect(iptc[kCGImagePropertyIPTCKeywords as String] == nil)
    }

    /// A title and a caption belong to one picture; an export preset has none to give. The
    /// author and the copyright exist on both, and the photo's own win: a preset says what to
    /// write on a picture that says nothing about itself.
    @Test func whatThePhotoSaysAboutItselfIsWrittenAndBeatsThePreset() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = ExportOptions()
        options.author = "Preset author"
        options.copyright = "© preset"
        let credits = PhotoCredits(
            title: "Rue de la Gare", caption: "Waiting for the last train.",
            author: "Yoan Bernabeu", copyright: "© 2026 Yoan Bernabeu"
        )
        let destination = folder.appendingPathComponent("credits.jpg")
        try Renderer.shared.write(picture, to: destination, options: options, credits: credits)
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any])
        #expect(iptc[kCGImagePropertyIPTCObjectName as String] as? String == "Rue de la Gare")
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String == "Waiting for the last train.")
        #expect(iptc[kCGImagePropertyIPTCByline as String] as? [String] == ["Yoan Bernabeu"])
        #expect(iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String == "© 2026 Yoan Bernabeu")
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFArtist as String] as? String == "Yoan Bernabeu")
        #expect(tiff[kCGImagePropertyTIFFCopyright as String] as? String == "© 2026 Yoan Bernabeu")
        #expect(tiff[kCGImagePropertyTIFFImageDescription as String] as? String == "Waiting for the last train.")
    }

    /// A photo that says nothing about itself is signed by the preset, as it was before the
    /// catalog had these fields. Blank is nothing, not an empty line written into the file.
    @Test func aPhotoThatSaysNothingIsSignedByThePreset() {
        var options = ExportOptions()
        options.author = "Preset author"
        options.copyright = "© preset"
        let blank = PhotoCredits(title: "  ", caption: "", author: " ", copyright: nil)
        #expect(blank.isEmpty)
        let iptc = Renderer.prepared(picture, options: options, credits: blank)
            .properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        #expect(iptc[kCGImagePropertyIPTCByline as String] as? [String] == ["Preset author"])
        #expect(iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String == "© preset")
        #expect(iptc[kCGImagePropertyIPTCObjectName as String] == nil)
    }

    /// The title and the caption are the photographer's, like the keywords: whatever the
    /// export keeps of the camera's own metadata, they go.
    @Test func theTitleSurvivesEveryMetadataChoice() {
        for choice in ExportOptions.Metadata.allCases {
            var options = ExportOptions()
            options.metadata = choice
            let written = Renderer.prepared(picture, options: options, credits: PhotoCredits(title: "Gare")).properties
            let iptc = written[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
            #expect(iptc[kCGImagePropertyIPTCObjectName as String] as? String == "Gare", "\(choice)")
        }
    }

    @Test func presetsMadeForTheWebLeaveThePlaceOut() throws {
        for preset in ExportPreset.builtIns {
            let isForTheWeb = preset.options.longEdge != nil
            #expect(preset.options.metadata == (isForTheWeb ? .withoutLocation : .all), "\(preset.name)")
        }
        // Presets written before the field existed keep everything, as they did.
        #expect(try JSONDecoder().decode(ExportOptions.self, from: Data(#"{"quality": 0.8}"#.utf8)).metadata == .all)
        var options = ExportOptions()
        options.metadata = .copyrightOnly
        #expect(try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(options)) == options)
    }
}
