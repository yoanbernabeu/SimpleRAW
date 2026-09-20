import Foundation
import RawEngine
import UniformTypeIdentifiers

public enum ImportError: LocalizedError, Equatable {
    /// A link, a folder, a device: nothing the library copies.
    case notARegularFile

    public var errorDescription: String? { "Not a regular file." }
}

/// What a folder or a memory card holds.
public struct ImportScan: Equatable, Sendable {
    /// In name order.
    public var photos: [URL] = []
    /// Files of a type the library does not take (videos, text), and links. Hidden files
    /// are not even counted.
    public var ignored: [URL] = []
}

public struct ImportSummary: Sendable {
    public struct Failure: Sendable {
        public let file: URL
        public let error: Error
    }

    public var imported: [Int64] = []
    public var duplicates: [URL] = []
    public var failures: [Failure] = []
    /// Left aside without being an error: not a type the library takes, or not a regular file.
    public var ignored: [URL] = []
}

/// Copies photos into the library and catalogs them. The source is never modified, and is
/// read only once.
public struct Importer: Sendable {
    typealias Copy = @Sendable (_ source: URL, _ destination: URL) throws -> String

    let library: Library
    let metadata: @Sendable (URL) throws -> FileMetadata
    let copy: Copy

    /// - Parameter metadata: how to read a file's metadata; the engine, unless a test says otherwise.
    public init(library: Library, metadata: @escaping @Sendable (URL) throws -> FileMetadata = FileMetadata.read(from:)) {
        self.init(library: library, metadata: metadata) { try HashingCopy.copy($0, to: $1) }
    }

    /// - Parameter copy: copies a file and returns its SHA-256; a test makes it fail half way.
    init(library: Library, metadata: @escaping @Sendable (URL) throws -> FileMetadata, copy: @escaping Copy) {
        self.library = library
        self.metadata = metadata
        self.copy = copy
    }

    /// What the library takes in: RAW files, and the rendered formats the engine develops too.
    public static let importedTypes: [UTType] = [.rawImage, .jpeg, .heic, .tiff, .png]

    /// Where files land while they are being copied: on the library's volume, so that moving
    /// them into place is a rename, and outside of what a backup uploads.
    public static let stagingFolder = "Importing"

    /// Throws away what an import that never finished left behind. A crash in the middle of
    /// one leaves a folder of half-copied files that nothing ever reads again, and that grows
    /// with every crash: the app sweeps it at launch.
    ///
    /// Only the staging folder, and only as a whole: an import that is running has its own
    /// folder inside it, so this is called before any import is, at launch.
    /// - Returns: how many interrupted imports were swept.
    @discardableResult
    public static func sweepInterruptedImports(in library: Library) throws -> Int {
        let staging = library.root.appendingPathComponent(stagingFolder)
        guard FileManager.default.fileExists(atPath: staging.path) else { return 0 }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path))?.count ?? 0
        try FileManager.default.removeItem(at: staging)
        return left
    }

    /// The photos under `folder`, however deep, hidden files aside, in name order.
    public static func scan(_ folder: URL) -> [URL] {
        survey(folder).photos
    }

    /// Whether this file is one the app opens. The one rule, asked wherever a file arrives
    /// from outside: the open panel, an import, and anything dropped on the window. A type
    /// is read off the file, never off its name.
    public static func opens(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              let type = values.contentType else { return false }
        return importedTypes.contains { type.conforms(to: $0) }
    }

    /// The photos under `folder`, and what is there that is not one.
    public static func survey(_ folder: URL) -> ImportScan {
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey, .isDirectoryKey]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var scan = ImportScan()
        for case let url as URL in enumerator ?? FileManager.DirectoryEnumerator() {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true else { continue }
            let isPhoto = values.isRegularFile == true && values.contentType.map { type in importedTypes.contains { type.conforms(to: $0) } } == true
            if isPhoto { scan.photos.append(url) } else { scan.ignored.append(url) }
        }
        let byName: (URL, URL) -> Bool = { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return ImportScan(photos: scan.photos.sorted(by: byName), ignored: scan.ignored.sorted(by: byName))
    }

    /// Imports what `survey` found, and keeps count of what it left aside.
    public func run(_ scan: ImportScan, preset: ImportPreset = ImportPreset.builtIns[0], progress: (URL) -> Void = { _ in }) -> ImportSummary {
        var summary = run(scan.photos, preset: preset, progress: progress)
        summary.ignored = scan.ignored + summary.ignored
        return summary
    }

    /// One file failing never stops the others.
    /// - Parameter progress: called before each file, in order.
    public func run(_ files: [URL], preset: ImportPreset = ImportPreset.builtIns[0], progress: (URL) -> Void = { _ in }) -> ImportSummary {
        var summary = ImportSummary()
        let staging = library.root.appendingPathComponent(Self.stagingFolder).appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: staging)
            // Only if no other import is using it: removing a folder that is not empty fails.
            rmdir(staging.deletingLastPathComponent().path)
        }
        for (index, file) in files.enumerated() {
            progress(file)
            do {
                // A folder each, so that the copy keeps the name of the file: its type is read off it.
                if let id = try importFile(file, preset: preset, staging: staging.appendingPathComponent("\(index)")) {
                    summary.imported.append(id)
                } else {
                    summary.duplicates.append(file)
                }
            } catch ImportError.notARegularFile {
                summary.ignored.append(file)
            } catch {
                summary.failures.append(.init(file: file, error: error))
            }
        }
        return summary
    }

    /// A file that fails leaves nothing behind, at any step: not half a copy, not a copy
    /// without a row, not a row without a copy.
    /// - Returns: the id of the new photo, or `nil` if the library already has this file.
    private func importFile(_ file: URL, preset: ImportPreset, staging: URL) throws -> Int64? {
        try FileManager.default.createPrivateDirectory(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        // One pass over the card: the bytes are hashed as they are copied, so the fingerprint
        // is that of the copy, and everything else is read from the copy.
        let copied = staging.appendingPathComponent(file.lastPathComponent)
        let hash = try copy(file, copied)
        guard try library.catalog.photoID(withContentHash: hash) == nil else { return nil }
        let metadata = try metadata(copied)

        let folder = Self.folder(for: metadata.captureDate)
        let name = Self.fileName(for: file, captureDate: metadata.captureDate, template: preset.fileNameTemplate)
        let destination = try freeDestination(named: name, in: library.originals.appendingPathComponent(folder))
        try FileManager.default.createPrivateDirectory(at: destination.deletingLastPathComponent())
        try FileManager.default.moveItem(at: copied, to: destination)

        do {
            // The row, its look, its keywords and its signature go in together, or not at all.
            return try library.catalog.database.transaction {
                let id = try library.catalog.add(NewPhoto(
                    relativePath: "\(Library.originalsFolder)/\(folder)/\(destination.lastPathComponent)",
                    fileName: destination.lastPathComponent, contentHash: hash, metadata: metadata
                ))
                if let look = preset.look {
                    var adjustments = Adjustments()
                    look.apply(to: &adjustments)
                    try library.catalog.setAdjustments(adjustments, for: id)
                }
                if !preset.keywords.isEmpty {
                    try library.catalog.setKeywords(preset.keywords, for: id)
                }
                if preset.signs {
                    try library.catalog.setSignature(author: preset.author, copyright: preset.copyright, for: [id])
                }
                return id
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Naming

    static func folder(for captureDate: Date?) -> String {
        guard let captureDate else { return "Undated" }
        let day = dayFormatter.string(from: captureDate)
        return "\(day.prefix(4))/\(day)"
    }

    /// Room kept in a file name for the "-2" of a name already taken.
    private static let numberRoom = 4

    /// The template comes from a JSON file, and `{name}` from a memory card: what they give
    /// is made a plain file name, as a whole, exactly as an export preset does. Nothing left
    /// of it: the name the file came with.
    static func fileName(for file: URL, captureDate: Date?, template: String) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        // An extension read off a card is text like any other, and decides the type of the copy.
        let ext = FileName.sanitized(file.pathExtension, fallback: "dat")
        let wanted = template
            .replacingOccurrences(of: "{name}", with: stem)
            .replacingOccurrences(of: "{date}", with: captureDate.map(stampFormatter.string(from:)) ?? "undated")
        return FileName.sanitized(wanted, fallback: stem, reserving: ext.utf8.count + 1 + numberRoom) + "." + ext
    }

    /// Two different files may share a name (two cards, two cameras): the second one gets
    /// "-2". A name that would land anywhere but in `folder` cannot happen once it has been
    /// sanitized; it is checked here all the same, where the copy is written.
    private func freeDestination(named name: String, in folder: URL) throws -> URL {
        let wanted = folder.appendingPathComponent(name)
        guard FileName.isContained(wanted, in: folder) else { throw ImportError.notARegularFile }
        return FileName.free(wanted)
    }

    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let stampFormatter = formatter("yyyyMMdd-HHmmss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }
}
