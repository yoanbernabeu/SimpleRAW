import Foundation
import ImageIO

/// What an exported file keeps of the metadata of its source. Pure: dictionaries in,
/// dictionaries out.
enum ExportMetadata {
    static func kept(_ properties: [String: Any], _ policy: ExportOptions.Metadata) -> [String: Any] {
        switch policy {
        case .all: properties
        case .withoutLocation: withoutLocation(properties)
        case .copyrightOnly: copyrightOnly(properties)
        }
    }

    /// Whole dictionaries that say where, or with whose camera. Maker notes are opaque and
    /// differ by brand ("{MakerCanon}", "{MakerApple}"…): they hold serial numbers, sometimes
    /// a place, and nothing a viewer needs.
    private static func withoutLocation(_ properties: [String: Any]) -> [String: Any] {
        var kept = properties.filter { key, _ in
            key != kCGImagePropertyGPSDictionary as String && key != kCGImagePropertyExifAuxDictionary as String && !key.hasPrefix("{Maker")
        }
        strip([kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifCameraOwnerName],
              from: kCGImagePropertyExifDictionary, in: &kept)
        strip([kCGImagePropertyDNGCameraSerialNumber], from: kCGImagePropertyDNGDictionary, in: &kept)
        strip([
            kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCCountryPrimaryLocationName,
            kCGImagePropertyIPTCContentLocationCode, kCGImagePropertyIPTCContentLocationName,
        ], from: kCGImagePropertyIPTCDictionary, in: &kept)
        return kept
    }

    /// Orientation is kept: it says nothing about anybody, and the picture must stay upright.
    private static func copyrightOnly(_ properties: [String: Any]) -> [String: Any] {
        var kept: [String: Any] = [:]
        kept[kCGImagePropertyOrientation as String] = properties[kCGImagePropertyOrientation as String]
        keep([kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFOrientation],
             of: kCGImagePropertyTIFFDictionary, from: properties, in: &kept)
        keep([kCGImagePropertyIPTCCopyrightNotice, kCGImagePropertyIPTCByline], of: kCGImagePropertyIPTCDictionary, from: properties, in: &kept)
        return kept
    }

    private static func strip(_ keys: [CFString], from dictionary: CFString, in properties: inout [String: Any]) {
        guard var values = properties[dictionary as String] as? [String: Any] else { return }
        for key in keys { values[key as String] = nil }
        properties[dictionary as String] = values.isEmpty ? nil : values
    }

    private static func keep(_ keys: [CFString], of dictionary: CFString, from properties: [String: Any], in kept: inout [String: Any]) {
        guard let values = properties[dictionary as String] as? [String: Any] else { return }
        let chosen = values.filter { key, _ in keys.contains { $0 as String == key } }
        if !chosen.isEmpty { kept[dictionary as String] = chosen }
    }
}
