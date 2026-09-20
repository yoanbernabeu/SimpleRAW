import Catalog
import Foundation
import RawEngine

/// The history of a photo, as it is kept between sessions.
public struct SavedHistory: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public let label: String
        public let adjustments: Adjustments
    }

    public var steps: [Step]
    public var cursor: Int
}

/// Where histories are kept. The develop view only knows files: the library answers for the
/// photos that are its own, and nothing does for the others.
public protocol HistoryStore: Sendable {
    func history(of photo: URL) throws -> SavedHistory?
    func save(_ history: SavedHistory, for photo: URL) throws
}

/// One small file per photo in the library's `History` folder. Steps differ by a slider or
/// two, so they are compressed together. Not in the catalog, which every backup sends whole:
/// like previews, a history is a comfort that can be lost without losing a photo.
public struct LibraryHistoryStore: HistoryStore {
    /// The most steps kept from one session to the next, the latest ones.
    static let keptSteps = 50

    private let library: Library

    public init(library: Library) {
        self.library = library
    }

    private var folder: URL { library.root.appendingPathComponent("History") }

    private func file(for photo: URL) throws -> URL? {
        try library.photo(forFileAt: photo).map { folder.appendingPathComponent("\($0.id).history") }
    }

    public func history(of photo: URL) throws -> SavedHistory? {
        guard let file = try file(for: photo), let packed = try? Data(contentsOf: file) else { return nil }
        let data = try (packed as NSData).decompressed(using: .zlib) as Data
        return try JSONDecoder().decode(SavedHistory.self, from: data)
    }

    public func save(_ history: SavedHistory, for photo: URL) throws {
        guard let file = try file(for: photo) else { return }
        var kept = history
        let dropped = max(0, kept.steps.count - Self.keptSteps)
        kept.steps.removeFirst(dropped)
        kept.cursor = max(0, kept.cursor - dropped)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let packed = try (JSONEncoder().encode(kept) as NSData).compressed(using: .zlib) as Data
        try packed.write(to: file, options: .atomic)
    }
}
