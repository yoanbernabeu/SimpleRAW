import Catalog
import Foundation
import RawEngine

/// One development of a photo, kept under a name.
public struct SavedVersion: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var name: String
    public let adjustments: Adjustments
}

/// Where the named versions of a photo are kept. The develop view only knows files: the
/// library answers for the photos that are its own, and nothing does for the others.
public protocol VersionStore: Sendable {
    /// `nil` when versions cannot be kept for this file.
    func versions(of photo: URL) throws -> [SavedVersion]?
    func save(_ adjustments: Adjustments, named name: String, for photo: URL) throws
    func rename(_ version: Int64, to name: String) throws
    func delete(_ version: Int64) throws
}

/// Versions of library photos live in the catalog, and are backed up with it.
public struct CatalogVersionStore: VersionStore {
    private let library: Library

    public init(library: Library) {
        self.library = library
    }

    public func versions(of photo: URL) throws -> [SavedVersion]? {
        guard let record = try library.photo(forFileAt: photo) else { return nil }
        // A version that can no longer be read is left out, not shown as a neutral one.
        return try library.catalog.versions(of: record.id).compactMap { version in
            (try? version.adjustments).map { SavedVersion(id: version.id, name: version.name, adjustments: $0) }
        }
    }

    public func save(_ adjustments: Adjustments, named name: String, for photo: URL) throws {
        guard let record = try library.photo(forFileAt: photo) else { return }
        try library.catalog.saveVersion(named: name, of: record.id, adjustments: adjustments)
    }

    public func rename(_ version: Int64, to name: String) throws {
        try library.catalog.renameVersion(version, to: name)
    }

    public func delete(_ version: Int64) throws {
        try library.catalog.deleteVersion(version)
    }
}
