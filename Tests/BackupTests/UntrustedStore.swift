import Foundation
@testable import Backup

/// A store that says what a test tells it to: listings and failures a real one would never
/// give, which is exactly what a compromised one would.
struct UntrustedStore: ObjectStore {
    let base: InMemoryObjectStore
    var listing: @Sendable ([S3Object]) -> [S3Object] = { $0 }
    var failingDownloads: Set<String> = []
    var failsToList = false

    func put(_ key: String, file: URL) async throws { try await base.put(key, file: file) }
    func put(_ key: String, data: Data) async throws { try await base.put(key, data: data) }
    func head(_ key: String) async throws -> S3Object? { try await base.head(key) }

    func list(prefix: String) async throws -> [S3Object] {
        guard !failsToList else { throw BackupError.storeUnavailable("") }
        return listing(try await base.list(prefix: prefix))
    }

    func get(_ key: String, to destination: URL) async throws {
        guard !failingDownloads.contains(key) else { throw BackupError.storeUnavailable(key) }
        try await base.get(key, to: destination)
    }
}

/// A store slow enough for uploads to overlap, that remembers how many did, and how often
/// it was listed.
final class ProbeStore: ObjectStore, @unchecked Sendable {
    private let base: InMemoryObjectStore
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var mostAtOnce = 0
    private(set) var listings = 0
    private(set) var heads = 0
    /// Files, in the order their upload started.
    private(set) var started: [String] = []

    init(base: InMemoryObjectStore = InMemoryObjectStore()) { self.base = base }

    private func overlapping<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        lock.withLock {
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        try await Task.sleep(for: .milliseconds(20))
        return try await work()
    }

    func put(_ key: String, file: URL) async throws {
        lock.withLock { started.append(key) }
        try await overlapping { try await base.put(key, file: file) }
    }

    func put(_ key: String, data: Data) async throws { try await base.put(key, data: data) }
    func get(_ key: String, to destination: URL) async throws { try await base.get(key, to: destination) }

    func head(_ key: String) async throws -> S3Object? {
        lock.withLock { heads += 1 }
        return try await overlapping { try await base.head(key) }
    }

    func list(prefix: String) async throws -> [S3Object] {
        lock.withLock { listings += 1 }
        return try await base.list(prefix: prefix)
    }
}
