import Foundation

extension JSONEncoder {
    /// How every document of the app is written: sorted keys and indentation, so that a file
    /// reads well, diffs well, and is the same bytes for the same settings. **Thumbnails are
    /// fingerprinted on this form**: changing it would render every one of them again.
    public static var document: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
