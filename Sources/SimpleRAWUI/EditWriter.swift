import Foundation
import RawEngine

/// Writes edits where they are kept, one at a time and in order, off the main actor: encoding
/// a document with painted masks and committing it to the catalog takes tens of milliseconds,
/// more when a backup holds the catalog.
final class EditWriter: Sendable {
    private let store: any AdjustmentsPersistence
    private let queue = DispatchQueue(label: "simpleraw.edit-writer", qos: .utility)

    init(store: any AdjustmentsPersistence) {
        self.store = store
    }

    /// Returns at once; `completion` hears about the outcome later, on the main actor.
    func write(_ adjustments: Adjustments, for photo: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        queue.async { [store] in
            let failure = Result { try store.save(adjustments, for: photo) }.failure
            Task { @MainActor in completion(failure) }
        }
    }

    /// Writes now, after whatever was already on its way: for when the photo is being left.
    func writeNow(_ adjustments: Adjustments, for photo: URL) throws {
        try queue.sync { try store.save(adjustments, for: photo) }
    }

    func load(for photo: URL) throws -> Adjustments? {
        try store.load(for: photo)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
