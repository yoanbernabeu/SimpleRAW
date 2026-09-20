import Catalog
import RawEngine

/// What is said about photos in words: to VoiceOver for a thumbnail, and under the grid.
enum PhotoCaption {
    /// "R0001.DNG, 3 stars, picked, red label, edited".
    static func accessibilityLabel(for photo: Photo) -> String {
        let flag: String? = switch photo.flag {
        case .picked: "picked"
        case .rejected: "rejected"
        case .none: nil
        }
        let parts: [String?] = [
            photo.fileName,
            photo.rating > 0 ? Count.of(photo.rating, "star") : nil,
            flag,
            photo.colorLabel.map { "\($0.rawValue) label" },
            photo.isEdited ? "edited" : nil,
        ]
        return parts.compactMap(\.self).joined(separator: ", ")
    }

    /// The line under the grid: how many photos are shown, how many are selected, or what the
    /// one selected photo is.
    static func summary(selected: [Photo], shown: Int) -> String {
        guard let photo = selected.first else { return Count.photos(shown) }
        guard selected.count == 1 else { return "\(Count.photos(selected.count)) selected" }
        let parts: [String?] = [
            photo.fileName,
            photo.camera,
            photo.iso.map(ExposureFormat.iso),
            photo.exposureTime.map { ExposureFormat.shutterSpeed($0) },
            photo.aperture.map { ExposureFormat.aperture($0) },
            photo.focalLength.map { ExposureFormat.focalLength($0) },
        ]
        return parts.compactMap(\.self).joined(separator: "  ·  ")
    }
}
