import Backup
import Foundation

/// What the backup settings window is filling in, and what it makes of it. The view binds
/// its fields to this and asks it everything else.
public struct BackupForm: Equatable, Sendable {
    public enum Problem: Error, LocalizedError, Equatable {
        case missingStorageName
        case missingAccount
        case endpoint(S3Endpoint.Problem)
        case naming(S3Naming.Problem)

        public var errorDescription: String? {
            switch self {
            case .missingStorageName: "Enter the name of the storage (the bucket) you created at your provider."
            case .missingAccount: "Enter your Cloudflare account ID: letters and digits, shown on the R2 page of your dashboard."
            case .endpoint(let problem): problem.errorDescription
            case .naming(let problem): problem.errorDescription
            }
        }
    }

    /// Where the two key fields stand. They are never prefilled: blank means "unchanged".
    public enum Keys: Equatable, Sendable {
        case complete
        /// Blank, and the keys in the Keychain were entered for this very destination.
        case keepsStored
        /// Blank, and there is nothing to keep.
        case needed
        /// Blank, but the stored keys belong to another server or bucket.
        case neededAgain
        /// One of the two is missing.
        case incomplete
    }

    public var provider: BackupProvider {
        didSet {
            guard provider != oldValue, !provider.regions.isEmpty, !provider.regions.contains(region) else { return }
            region = provider.defaultRegion
        }
    }

    public var region: String
    /// Cloudflare only.
    public var account = ""
    /// The address, typed: `BackupProvider.other` only.
    public var endpoint = ""
    public var storageName = ""
    public var folder = "simpleraw"
    public var accessKey = ""
    public var secretKey = ""

    public init(saved: S3Configuration?) {
        guard let saved else {
            provider = .amazonS3
            region = BackupProvider.amazonS3.defaultRegion
            return
        }
        let match = BackupProvider.matching(endpoint: saved.endpoint)
        provider = match.provider
        account = match.account
        region = saved.region
        if match.provider == .other { endpoint = saved.endpoint.absoluteString }
        storageName = saved.bucket
        folder = saved.prefix
    }

    /// The address, from the table or as typed.
    private var endpointText: Result<String, Problem> {
        if provider == .other { return .success(endpoint) }
        guard let text = provider.endpoint(region: region, account: account.lowercased()) else {
            return .failure(provider.needsAccount ? .missingAccount : .naming(.invalidRegion))
        }
        return .success(text)
    }

    private var validatedEndpoint: Result<S3Endpoint.Validated, Problem> {
        endpointText.flatMap { text in
            Result { try S3Endpoint.validate(text) }.mapError { .endpoint($0 as? S3Endpoint.Problem ?? .notAWebAddress) }
        }
    }

    /// What would be saved, through the one way in of the backup module.
    public var configuration: Result<S3Configuration, Problem> {
        guard !storageName.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.missingStorageName) }
        return endpointText.flatMap { text in
            Result { try S3Configuration.validated(endpoint: text, region: region, bucket: storageName, prefix: folder) }.mapError {
                switch $0 {
                case let problem as S3Naming.Problem: .naming(problem)
                case let problem as S3Endpoint.Problem: .endpoint(problem)
                default: .endpoint(.notAWebAddress)
                }
            }
        }
    }

    /// What is wrong with the address, once there is something to judge.
    public var endpointProblem: Problem? {
        guard case .failure(let problem) = validatedEndpoint else { return nil }
        if provider == .other, endpoint.isEmpty { return nil }
        if problem == .missingAccount, account.isEmpty { return nil }
        return problem
    }

    /// What the window points at: a mistake in what was typed, never a field still empty.
    public var visibleProblem: Problem? {
        if let endpointProblem { return endpointProblem }
        if case .failure(.naming(let problem)) = configuration { return .naming(problem) }
        return nil
    }

    /// Plain http: allowed, never silent.
    public var isInsecure: Bool {
        (try? validatedEndpoint.get().isInsecure) ?? false
    }

    public func keys(saved: S3Configuration?) -> Keys {
        switch (accessKey.isEmpty, secretKey.isEmpty) {
        case (false, false): return .complete
        case (true, true):
            guard let saved else { return .needed }
            guard let configuration = try? configuration.get() else { return .keepsStored }
            return BackupSession.keysAccount(for: saved) == BackupSession.keysAccount(for: configuration) ? .keepsStored : .neededAgain
        default: return .incomplete
        }
    }

    public func canSubmit(saved: S3Configuration?) -> Bool {
        guard case .success = configuration else { return false }
        return [.complete, .keepsStored].contains(keys(saved: saved))
    }
}
