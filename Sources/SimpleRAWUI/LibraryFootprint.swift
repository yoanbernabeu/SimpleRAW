import Catalog
import Foundation

/// How much the library holds. Walking the folder takes a while on a large library: `measure`
/// is called off the main actor.
struct LibraryFootprint: Equatable, Sendable {
    var photoCount: Int
    var bytes: Int64

    static func measure(_ library: Library) -> LibraryFootprint {
        let count = (try? library.catalog.count(matching: PhotoFilter())) ?? 0
        var bytes: Int64 = 0
        let files = FileManager.default.enumerator(at: library.root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let file = files?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
        }
        return LibraryFootprint(photoCount: count, bytes: bytes)
    }

    var text: String {
        let locale = Locale(identifier: "en_US")
        let photos = "\(photoCount.formatted(.number.locale(locale))) photo\(photoCount == 1 ? "" : "s")"
        return "\(photos), \(bytes.formatted(.byteCount(style: .file).locale(locale))) on disk"
    }
}
