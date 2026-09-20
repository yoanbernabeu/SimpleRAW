import CryptoKit
import Foundation

/// Where a backup goes. `S3Client` is one; tests use another, in memory.
public protocol ObjectStore: Sendable {
    func put(_ key: String, file: URL) async throws
    func put(_ key: String, data: Data) async throws
    func list(prefix: String) async throws -> [S3Object]
    /// `nil` when there is no such object. Unlike a listing, it says the fingerprint the
    /// object was uploaded with.
    func head(_ key: String) async throws -> S3Object?
    func get(_ key: String, to destination: URL) async throws
}

extension S3Client: ObjectStore {}

/// A store that lives and dies with the process. It keeps the contract of a real one: keys,
/// sizes, and failures on demand.
public final class InMemoryObjectStore: ObjectStore, @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data]
    /// What a real store keeps as metadata: the SHA-256 each object came with.
    private var fingerprints: [String: String] = [:]
    private let failingKeys: Set<String>

    public init(failingKeys: Set<String> = []) {
        objects = [:]
        self.failingKeys = failingKeys
    }

    /// Same content, no failure any more: a store that recovered.
    public init(adopting other: InMemoryObjectStore) {
        (objects, fingerprints) = other.lock.withLock { (other.objects, other.fingerprints) }
        failingKeys = []
    }

    public func put(_ key: String, file: URL) async throws {
        try await put(key, data: try Data(contentsOf: file))
    }

    public func put(_ key: String, data: Data) async throws {
        guard !failingKeys.contains(key) else { throw BackupError.storeUnavailable(key) }
        lock.withLock {
            objects[key] = data
            fingerprints[key] = BackupHash.sha256(of: data)
        }
    }

    /// An object from before uploads carried a fingerprint.
    func putWithoutFingerprint(_ key: String, data: Data) {
        lock.withLock {
            objects[key] = data
            fingerprints[key] = nil
        }
    }

    public func head(_ key: String) async throws -> S3Object? {
        lock.withLock {
            objects[key].map { S3Object(key: key, size: $0.count, etag: BackupHash.sha256(of: $0), sha256: fingerprints[key]) }
        }
    }

    public func list(prefix: String) async throws -> [S3Object] {
        lock.withLock {
            objects.filter { $0.key.hasPrefix(prefix) }
                .map { S3Object(key: $0.key, size: $0.value.count, etag: BackupHash.sha256(of: $0.value)) }
                .sorted { $0.key < $1.key }
        }
    }

    public func get(_ key: String, to destination: URL) async throws {
        guard let data = lock.withLock({ objects[key] }) else { throw BackupError.storeUnavailable(key) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }
}

public enum BackupError: Error, LocalizedError, Equatable {
    case storeUnavailable(String)
    case destinationNotEmpty(URL)
    case nothingToRestore
    case sizeMismatch(key: String, announced: Int, received: Int)
    case linkNotBackedUp(String)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable(let key): "The backup store failed on \(key)"
        case .destinationNotEmpty(let url): "\(url.path) is not empty: a restore never overwrites an existing library"
        case .nothingToRestore: "There is no backup to restore from"
        case .linkNotBackedUp(let path):
            "\(path) is a link that does not lead to a file of the library: it is not backed up. Move what it points to into the library"
        case .sizeMismatch(let key, let announced, let received):
            "\(key) was announced as \(announced) bytes and came as \(received) bytes: it was not kept"
        }
    }
}

public enum BackupHash {
    static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streamed: originals are tens of megabytes.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
