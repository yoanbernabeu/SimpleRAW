/// Thumbnails dragged to an album travel as plain text: an unbundled app cannot declare a
/// type of its own, and text needs none.
enum PhotoDrag {
    private static let prefix = "simpleraw-photos:"

    static func text(for ids: [Int64]) -> String {
        prefix + ids.map(String.init).joined(separator: ",")
    }

    /// `nil` for any text that is not a drag of photos.
    static func photoIDs(in text: String) -> [Int64]? {
        guard text.hasPrefix(prefix) else { return nil }
        let fields = text.dropFirst(prefix.count).split(separator: ",", omittingEmptySubsequences: false)
        let ids = fields.compactMap { Int64($0) }
        return ids.isEmpty || ids.count != fields.count ? nil : ids
    }
}
