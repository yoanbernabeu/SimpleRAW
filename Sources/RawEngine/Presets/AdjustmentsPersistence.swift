import Foundation

/// Where the edits of a photo are kept between sessions: a sidecar file, a catalog…
public protocol AdjustmentsPersistence: Sendable {
    /// `nil` when nothing was saved for this photo.
    func load(for photo: URL) throws -> Adjustments?
    func save(_ adjustments: Adjustments, for photo: URL) throws
}
