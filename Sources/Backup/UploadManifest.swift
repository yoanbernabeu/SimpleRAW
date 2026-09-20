import Catalog
import Foundation

/// What previous runs put in the store, remembered in a file next to the library, so that a
/// run does not start by listing the whole bucket: fifty requests, paid for, at 50 000 objects.
///
/// It is a memory, not the truth, and it is only believed when it is about the same
/// destination, read without trouble, and young enough. A run that had a failure forgets it;
/// "Verify Backup" rewrites it from the store. In every other case the store is listed, as
/// if there were no manifest. It is a file of its own rather than a table of the catalog:
/// writing it must not change the catalog, which would then go up again for nothing.
public struct UploadManifest: Sendable {
    public struct Remembered: Equatable, Sendable {
        /// Size by key, as a listing would say.
        public var objects: [String: Int]
        /// When the store itself was last asked.
        public var listedAt: Date
    }

    public let file: URL
    let destination: String
    let maximumAge: TimeInterval
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - destination: what tells one store from another, such as
    ///     `S3Configuration.destinationIdentity`: what went to one bucket says nothing of another.
    ///   - maximumAge: how long the store goes without being listed. What disappears from it
    ///     in the meantime goes unnoticed for that long.
    public init(file: URL, destination: String, maximumAge: TimeInterval = 7 * 24 * 3600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.destination = destination
        self.maximumAge = maximumAge
        self.now = now
    }

    /// In the library, outside of the folders that are backed up.
    public static func defaultFile(in library: Library) -> URL {
        library.root.appendingPathComponent("backup-manifest.json")
    }

    private struct Document: Codable {
        static let currentVersion = 1
        var version = Document.currentVersion
        var destination: String
        var listedAt: Date
        var objects: [String: Int]
    }

    /// `nil` when the store has to be asked.
    func remembered() -> Remembered? {
        guard let data = try? Data(contentsOf: file), let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == Document.currentVersion, document.destination == destination else { return nil }
        let age = now().timeIntervalSince(document.listedAt)
        guard (0...maximumAge).contains(age) else { return nil }
        return Remembered(objects: document.objects, listedAt: document.listedAt)
    }

    func remember(_ remembered: Remembered) {
        let document = Document(destination: destination, listedAt: remembered.listedAt, objects: remembered.objects)
        guard let data = try? JSONEncoder().encode(document), (try? data.write(to: file, options: .atomic)) != nil else {
            // A manifest that cannot be written must not leave an older one to be believed.
            return forget()
        }
    }

    func forget() { try? FileManager.default.removeItem(at: file) }
}

extension S3Configuration {
    /// Tells this destination from another. The region is not part of it: it says how to
    /// sign, not where things go.
    public var destinationIdentity: String {
        "\(endpoint.absoluteString)|\(bucket)|\(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }
}
