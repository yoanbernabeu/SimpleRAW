import Catalog
import Foundation

public struct BackupProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int
    public let currentKey: String
}

public struct BackupReport: Sendable {
    public struct Failure: Sendable {
        public let key: String
        public let error: Error
    }

    public var uploaded: [String] = []
    /// Already in the store, unchanged.
    public var skipped = 0
    public var failures: [Failure] = []
}

public struct RestoreReport: Equatable, Sendable {
    public var downloaded = 0
    /// Originals whose content does not match the hash the catalog has for them.
    public var corrupted: [String] = []
    /// Originals the catalog knows but the backup does not have.
    public var missing: [String] = []
    /// Keys found in the store that a backup would never have written, or that point outside
    /// of the destination. They are left where they are.
    public var rejected: [String] = []
    /// Objects that could not be brought back, and why. The others were.
    public var failures: [RestoreFailure] = []
    /// Photos the catalog places outside of the library. Their path is never followed: they
    /// are lost to this restore, and said to be.
    public var escaping: [String] = []
}

public struct RestoreFailure: Equatable, Sendable {
    public let key: String
    public let reason: String
}

/// What "Verify Backup" found, without downloading anything: every file the library has, or
/// that its catalog knows, against what the store says it holds.
public struct VerificationReport: Equatable, Sendable {
    /// How many files were looked for in the store, the catalog included.
    public var checked = 0
    /// Not in the store.
    public var missing: [String] = []
    /// In the store, with another size.
    public var sizeMismatches: [String] = []
    /// In the store with the right size, and a fingerprint that is not the file's.
    public var fingerprintMismatches: [String] = []
    /// In the store with the right size, uploaded before fingerprints were: nothing more
    /// can be said without downloading them. Not a problem, and not a proof either.
    public var withoutFingerprint: [String] = []
    /// Could not be asked about: the store failed on them.
    public var unverified: [String] = []

    public init(checked: Int = 0) { self.checked = checked }

    public var isSound: Bool {
        missing.isEmpty && sizeMismatches.isEmpty && fingerprintMismatches.isEmpty && unverified.isEmpty
    }
}

/// Backs a library up to an object store, and restores it.
///
/// What goes up: the originals, the exports, and a consistent snapshot of the catalog, which
/// holds every rating, keyword, album and edit. Previews do not: they can be rendered again.
/// It is a backup, not a mirror: nothing is ever deleted from the store.
public struct LibraryBackup: Sendable {
    /// Folders of the library that are backed up, besides the catalog.
    static let backedUpFolders = [Library.originalsFolder, Library.exportsFolder]
    static let catalogKey = "catalog.sqlite"
    /// The hash of the catalog snapshot last uploaded, next to it: how a run knows whether
    /// the catalog changed without downloading it.
    static let catalogHashKey = "catalog.sqlite.sha256"

    /// How many requests are in flight at once, uploads in a run and questions in a verification.
    static let concurrentRequests = 3

    let library: Library
    let store: any ObjectStore
    let manifest: UploadManifest?
    /// - Parameter manifest: remembers what runs sent, so that the next one does not list
    ///   the whole store. Without one, every run does.
    public init(library: Library, store: any ObjectStore, manifest: UploadManifest? = nil) {
        self.library = library
        self.store = store
        self.manifest = manifest
    }

    /// Uploads what the store does not have yet. One file failing never stops the others,
    /// and the next run picks up what this one missed.
    /// - Parameter progress: called once before anything is sent, then each time a file is
    ///   done, sent or not: it ends on the total. A few files go up at once.
    public func run(progress: @Sendable (BackupProgress) -> Void = { _ in }) async -> BackupReport {
        var report = BackupReport()
        // What the store holds: remembered when it can be, asked of the store otherwise.
        var known: UploadManifest.Remembered
        if let remembered = manifest?.remembered() {
            known = remembered
        } else {
            do {
                let listing = try await store.list(prefix: "")
                known = .init(objects: Dictionary(listing.map { ($0.key, $0.size) }, uniquingKeysWith: { first, _ in first }), listedAt: manifest?.now() ?? Date())
            } catch {
                report.failures.append(.init(key: "", error: error))
                return report
            }
        }

        // Files are immutable once in the library: same key and same size means same file.
        var pending: [(key: String, file: URL, size: Int)] = []
        let local = localFiles()
        report.failures += local.links.map { .init(key: $0, error: BackupError.linkNotBackedUp($0)) }
        for (key, file, size) in local.files {
            if known.objects[key] == size { report.skipped += 1 } else { pending.append((key, file, size)) }
        }

        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-catalog-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: snapshot) }
        var catalogHash: String?
        do {
            try library.catalog.snapshot(to: snapshot)
            // Read off the snapshot itself: the live catalog may have moved on already.
            let hash = try PhotoCatalog.contentFingerprint(ofCatalogAt: snapshot)
            let uploaded = try? await remoteCatalogHash()
            if uploaded == hash, known.objects[Self.catalogKey] != nil {
                report.skipped += 1
            } else {
                pending.append((Self.catalogKey, snapshot, (try? snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1))
                catalogHash = hash
            }
        } catch {
            report.failures.append(.init(key: Self.catalogKey, error: error))
        }

        guard let first = pending.first else {
            manifest?.remember(known)
            return report
        }
        progress(BackupProgress(done: 0, total: pending.count, currentKey: first.key))
        let store = store
        // The catalog goes last, alone: a run cut short leaves a catalog in the store that
        // speaks of originals that are there, not of ones that were still on their way.
        let files = pending.filter { $0.key != Self.catalogKey }
        var errors = await BoundedConcurrency.map(files, limit: Self.concurrentRequests) { count, item in
            progress(BackupProgress(done: count, total: pending.count, currentKey: item.key))
        } _: { item -> (any Error)? in
            do {
                try await store.put(item.key, file: item.file)
                return nil
            } catch {
                return error
            }
        }
        if let catalogHash {
            do {
                try await store.put(Self.catalogKey, file: snapshot)
                // Only once the catalog is up: the hash says what is in the store.
                try await store.put(Self.catalogHashKey, data: Data(catalogHash.utf8))
                errors.append(nil)
            } catch {
                errors.append(error)
            }
            progress(BackupProgress(done: pending.count, total: pending.count, currentKey: Self.catalogKey))
        }
        for (item, error) in zip(pending, errors) {
            if let error {
                report.failures.append(.init(key: item.key, error: error))
            } else {
                report.uploaded.append(item.key)
                known.objects[item.key] = item.size
            }
        }
        // After a failure nobody knows what the store holds: the next run asks it.
        if errors.contains(where: { $0 != nil }) { manifest?.forget() } else { manifest?.remember(known) }
        return report
    }

    /// Compares the library with what the store holds: presence and size from one listing,
    /// then the fingerprint each object was uploaded with. Originals are held to the hash the
    /// catalog took at import, even when they are no longer on disk; other files are read.
    /// Nothing is downloaded, uploaded or repaired: the next `run` sends what is missing.
    /// - Throws: when the store cannot be listed or the catalog cannot be read.
    public func verify(progress: @Sendable (BackupProgress) -> Void = { _ in }) async throws -> VerificationReport {
        let remote = Dictionary(try await store.list(prefix: "").map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // The store has just said what it holds: whatever a manifest remembered is replaced.
        manifest?.remember(.init(objects: remote.mapValues(\.size), listedAt: manifest?.now() ?? Date()))

        var expected: [String: (size: Int?, file: URL?, fingerprint: String?)] = [:]
        for (key, file, size) in localFiles().files { expected[key] = (size, file, nil) }
        for photo in try library.catalog.photos(matching: PhotoFilter()) {
            let onDisk = expected[photo.relativePath]
            expected[photo.relativePath] = (onDisk?.size, onDisk?.file, photo.contentHash)
        }

        var report = VerificationReport()
        // The catalog in the store is a snapshot of another moment: only its presence is checked.
        report.checked = 1
        if remote[Self.catalogKey] == nil { report.missing.append(Self.catalogKey) }

        let items = expected.keys.sorted().map { key in
            Expectation(key: key, size: expected[key]?.size, file: expected[key]?.file, fingerprint: expected[key]?.fingerprint, listed: remote[key])
        }
        report.checked += items.count
        if let first = items.first { progress(BackupProgress(done: 0, total: items.count, currentKey: first.key)) }
        let store = store
        let findings = await BoundedConcurrency.map(items, limit: Self.concurrentRequests) { count, item in
            progress(BackupProgress(done: count, total: items.count, currentKey: item.key))
        } _: { item in
            await item.finding(in: store)
        }
        for (item, finding) in zip(items, findings) {
            switch finding {
            case .sound: break
            case .missing: report.missing.append(item.key)
            case .anotherSize: report.sizeMismatches.append(item.key)
            case .anotherFingerprint: report.fingerprintMismatches.append(item.key)
            case .withoutFingerprint: report.withoutFingerprint.append(item.key)
            case .unverified: report.unverified.append(item.key)
            }
        }
        return report
    }

    /// Rebuilds a library from its backup, into an empty folder, then checks every original
    /// against the hash the catalog has for it.
    /// - Throws: when nothing was written: no backup, a folder that is not empty, or no
    ///   catalog to be had. After that, what goes wrong is in the report.
    public static func restore(from store: any ObjectStore, to destination: URL, progress: @Sendable (BackupProgress) -> Void = { _ in }) async throws -> RestoreReport {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        guard existing.isEmpty else { throw BackupError.destinationNotEmpty(destination) }

        let listing = try await store.list(prefix: "").filter { $0.key != catalogHashKey }
        guard let catalog = listing.first(where: { $0.key == catalogKey }) else { throw BackupError.nothingToRestore }
        // The catalog comes first: if it cannot be had, the folder is still empty and the
        // restore can be tried again.
        let objects = [catalog] + listing.filter { $0.key != catalogKey }

        var report = RestoreReport()
        for (index, object) in objects.enumerated() {
            progress(BackupProgress(done: index, total: objects.count, currentKey: object.key))
            // The store is not trusted: its keys decide nothing about where files go.
            guard let target = safeDestination(forKey: object.key, in: destination),
                  !FileManager.default.fileExists(atPath: target.path) else {
                report.rejected.append(object.key)
                continue
            }
            do {
                try await store.get(object.key, to: target)
                // Nor do its files get to be another size than the one it announced.
                let received = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                guard received == object.size else {
                    throw BackupError.sizeMismatch(key: object.key, announced: object.size, received: received)
                }
                // Nor is its catalog opened before it is known to be one of ours: what it
                // holds beyond the tables of the app would run inside the app.
                if object.key == catalogKey {
                    report.escaping = try PhotoCatalog.validateForeignCatalog(at: target).escapingPaths
                }
            } catch {
                try? FileManager.default.removeItem(at: target)
                // Without its catalog a library is a pile of files: better to start again.
                guard object.key != catalogKey else { throw error }
                // One file failing never stops the others, as in a run.
                report.failures.append(RestoreFailure(key: object.key, reason: error.localizedDescription))
                continue
            }
            report.downloaded += 1
        }

        let library = try Library(root: destination)
        for photo in try library.catalog.photos(matching: PhotoFilter()) {
            let file = library.url(for: photo)
            guard FileManager.default.fileExists(atPath: file.path) else {
                report.missing.append(photo.relativePath)
                continue
            }
            if try BackupHash.sha256(of: file) != photo.contentHash { report.corrupted.append(photo.relativePath) }
        }
        return report
    }

    // MARK: - Verification

    /// What one file should be in the store, and what the listing said of it.
    private struct Expectation: Sendable {
        enum Finding: Sendable { case sound, missing, anotherSize, anotherFingerprint, withoutFingerprint, unverified }

        let key: String
        /// `nil` for an original that is no longer on disk: the catalog still vouches for it.
        let size: Int?
        let file: URL?
        let fingerprint: String?
        let listed: S3Object?

        func finding(in store: any ObjectStore) async -> Finding {
            guard let listed else { return .missing }
            if let size, size != listed.size { return .anotherSize }
            do {
                guard let head = try await store.head(key) else { return .missing }
                guard let uploaded = head.sha256 else { return .withoutFingerprint }
                let expected = try fingerprint ?? file.map(BackupHash.sha256(of:))
                return uploaded == expected ? .sound : .anotherFingerprint
            } catch {
                return .unverified
            }
        }
    }

    // MARK: - Untrusted keys

    /// Where a key of the store may be written under `root`, or `nil` if it may not be.
    ///
    /// Only what a backup writes is accepted (the catalog, and files under the backed-up
    /// folders), and only plain relative paths: no empty, `.` or `..` component, no absolute
    /// path, no control character. The result is checked again to lie under `root`.
    static func safeDestination(forKey key: String, in root: URL) -> URL? {
        let isCatalog = key == catalogKey
        guard isCatalog || backedUpFolders.contains(where: { key.hasPrefix($0 + "/") }) else { return nil }
        let components = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && !component.hasPrefix("~")
                && component.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        }) else { return nil }

        let candidate = components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    // MARK: - Internals

    /// The files of the backed-up folders, each under a key made of the names walked through
    /// to reach it, and the links that lead somewhere else.
    ///
    /// A key is never cut out of an absolute path: with `Originals` linked from another disk,
    /// what was left after the cut was a piece of that disk's path. And a link is never
    /// followed out of the library: what goes up is what the library holds.
    ///
    /// Type, link and size come with the enumeration, in one pass over the folders: no
    /// question is asked of the disk per file, which is what counts with 50 000 of them.
    private func localFiles() -> (files: [(key: String, file: URL, size: Int)], links: [String]) {
        let root = library.root.resolvingSymlinksInPath().path + "/"
        var files: [(key: String, file: URL, size: Int)] = []
        var links: [String] = []
        for folder in Self.backedUpFolders {
            var directory = library.root.appendingPathComponent(folder)
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                directory = directory.resolvingSymlinksInPath()
                guard directory.path.hasPrefix(root) else {
                    links.append(folder)
                    continue
                }
            }
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                // As deep as the enumerator is, so many names: however it spells what is above.
                let key = ([folder] + url.pathComponents.suffix(enumerator.level)).joined(separator: "/")
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true {
                    files.append((key, url, values?.fileSize ?? -1))
                } else if values?.isSymbolicLink == true {
                    // Rare enough to be asked about one by one.
                    let target = url.resolvingSymlinksInPath()
                    let file = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    if file?.isRegularFile == true, target.path.hasPrefix(root) { files.append((key, target, file?.fileSize ?? -1)) } else { links.append(key) }
                }
            }
        }
        return (files.sorted { $0.key < $1.key }, links.sorted())
    }

    private func remoteCatalogHash() async throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try await store.get(Self.catalogHashKey, to: file)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
