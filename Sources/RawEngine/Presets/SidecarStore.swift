import Foundation

/// Keeps the adjustments of a photo in a JSON file of its own, so that edits outlive the
/// session. The original is never touched. The catalog will later take these files over.
public struct SidecarStore: AdjustmentsPersistence {
    static let suffix = "simpleraw.json"

    /// Where sidecars go. `nil` = next to each photo.
    private let directory: URL?
    /// Whether files are named after the photo or after a fingerprint of it. A folder shared
    /// by photographs from everywhere needs the second: two people's `R0001.DNG` are two
    /// photographs.
    private let isPrivate: Bool

    public init(directory: URL? = nil) {
        self.directory = directory
        isPrivate = false
    }

    /// Edits kept in a folder of the app's own, under a fingerprint of the photograph.
    ///
    /// This is what a sandbox leaves: opening `photo.DNG` gives the right to that one file,
    /// never to write another name beside it. Settings written beside a photograph by an
    /// earlier version are still read — see `load` — so nothing anybody made is lost, and
    /// nothing has to go looking through a disk the app may no longer look through.
    public static func inPrivateFolder(_ folder: URL) -> SidecarStore {
        SidecarStore(directory: folder, isPrivate: true)
    }

    /// Where the app keeps them: `Application Support/SimpleRAW/Edits`, which inside a sandbox
    /// is the app's container and outside it the usual place.
    public static var applicationSupport: SidecarStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return inPrivateFolder(base.appendingPathComponent("SimpleRAW").appendingPathComponent("Edits"))
    }

    private init(directory: URL?, isPrivate: Bool) {
        self.directory = directory
        self.isPrivate = isPrivate
    }

    /// Named after the whole file name, extension included: a RAW and a JPEG that share a
    /// stem must not share their settings.
    public func sidecarURL(for photo: URL) -> URL {
        (directory ?? photo.deletingLastPathComponent())
            .appendingPathComponent(isPrivate ? PhotoFingerprint.of(photo) : photo.lastPathComponent)
            .appendingPathExtension(Self.suffix)
    }

    /// `nil` when the photo has no sidecar. A sidecar that cannot be read is an error: better
    /// to say so than to silently start over and then overwrite it.
    ///
    /// A private store falls back to what an earlier version wrote beside the photograph, and
    /// stops doing so the moment it has an answer of its own.
    public func load(for photo: URL) throws -> Adjustments? {
        let file = sidecarURL(for: photo)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return isPrivate ? try SidecarStore().load(for: photo) : nil
        }
        return try Adjustments(contentsOf: file)
    }

    /// A neutral document is stored as no file at all: untouched photos leave no clutter.
    ///
    /// A sidecar that cannot be read — damaged, or written by a newer version — is somebody's
    /// work: it is set aside under another name before anything is written or deleted.
    public func save(_ adjustments: Adjustments, for photo: URL) throws {
        let file = sidecarURL(for: photo)
        try setAsideIfUnreadable(file)
        guard adjustments != Adjustments() else {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try adjustments.jsonData().write(to: file, options: .atomic)
    }

    private func setAsideIfUnreadable(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path), (try? Adjustments(contentsOf: file)) == nil else { return }
        let stem = file.deletingPathExtension().lastPathComponent
        var attempt = 1
        var kept: URL
        repeat {
            let suffix = attempt == 1 ? "unreadable" : "unreadable-\(attempt)"
            kept = file.deletingLastPathComponent().appendingPathComponent("\(stem).\(suffix).json")
            attempt += 1
        } while FileManager.default.fileExists(atPath: kept.path)
        try FileManager.default.moveItem(at: file, to: kept)
    }
}
