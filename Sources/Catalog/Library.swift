import Foundation

/// A managed library: one folder holding the originals, the catalog and the previews.
/// Everything inside is addressed relative to it, so the folder can be moved or backed up
/// as a whole.
public struct Library: Sendable {
    public let root: URL
    public let catalog: PhotoCatalog

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createPrivateDirectory(at: root)
        catalog = try PhotoCatalog(url: root.appendingPathComponent("catalog.sqlite"))
    }

    /// The first component of every photo's `relativePath`.
    public static let originalsFolder = "Originals"

    public var originals: URL { root.appendingPathComponent(Self.originalsFolder) }
    /// Where exports go unless told otherwise: inside the library, so that they are backed up
    /// with it.
    public static let exportsFolder = "Exports"
    public var exports: URL { root.appendingPathComponent(Self.exportsFolder) }

    /// The exports folder, created if this is the first export.
    public func preparedExportsFolder() throws -> URL {
        try FileManager.default.createPrivateDirectory(at: exports)
        return exports
    }
    public var previews: URL { root.appendingPathComponent("Previews") }

    /// Where the original of a photo is. A catalog may come from a backup store, which is not
    /// trusted: a path that leaves the originals resolves to a file that does not exist, so that
    /// nothing else can be read, exported or sent to the Trash through it.
    public func url(for photo: Photo) -> URL {
        guard Self.isConfined(relativePath: photo.relativePath) else {
            return root.appendingPathComponent("Invalid").appendingPathComponent("\(photo.id)")
        }
        return root.appendingPathComponent(photo.relativePath)
    }

    /// The one rule for a `relative_path`: plain components under `Originals`. No `..`, which
    /// could also come back inside the library and point at the catalog itself, no absolute
    /// path, no empty component.
    public static func isConfined(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return components.count >= 2 && components[0] == originalsFolder
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
    }

    /// `~/Pictures/SimpleRAW Library`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("SimpleRAW Library")
    }
}

extension FileManager {
    /// A folder for its owner only (0700), parents included. A library may sit on a shared
    /// volume, and says a lot about who made it. Folders that exist already are left as they
    /// are: someone who shares one on purpose keeps it shared.
    func createPrivateDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
