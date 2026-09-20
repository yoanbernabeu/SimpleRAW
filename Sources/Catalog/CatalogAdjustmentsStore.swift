import Foundation
import RawEngine

/// Keeps the edits of library photos in the catalog, where they can be filtered on and
/// backed up with everything else. A file that is not part of the library goes to `fallback`.
public struct CatalogAdjustmentsStore: AdjustmentsPersistence {
    private let library: Library
    private let fallback: (any AdjustmentsPersistence)?

    public init(library: Library, fallback: (any AdjustmentsPersistence)? = SidecarStore()) {
        self.library = library
        self.fallback = fallback
    }

    public func load(for photo: URL) throws -> Adjustments? {
        guard let record = try record(for: photo) else { return try fallback?.load(for: photo) }
        return record.isEdited ? record.adjustments : nil
    }

    public func save(_ adjustments: Adjustments, for photo: URL) throws {
        guard let record = try record(for: photo) else {
            try fallback?.save(adjustments, for: photo)
            return
        }
        try library.catalog.setAdjustments(adjustments, for: record.id)
    }

    private func record(for photo: URL) throws -> Photo? {
        try library.photo(forFileAt: photo)
    }
}

extension Library {
    /// The photo of the catalog whose original is `file`; `nil` for a file from elsewhere.
    public func photo(forFileAt file: URL) throws -> Photo? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath) else { return nil }
        return try catalog.photo(atRelativePath: String(path.dropFirst(rootPath.count)))
    }
}

extension PhotoCatalog {
    public func photo(atRelativePath path: String) throws -> Photo? {
        try database.query("SELECT * FROM photos WHERE relative_path = ?", [.text(path)], map: Self.photo(from:)).first
    }
}
