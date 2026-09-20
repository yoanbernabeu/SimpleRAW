import Foundation
import Security

/// Where S3 keys are kept. Never in a settings file: in the Keychain.
public protocol CredentialStore: Sendable {
    func credentials(for account: String) -> S3Credentials?
    func save(_ credentials: S3Credentials, for account: String) throws
    func delete(account: String)
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: S3Credentials] = [:]

    public init() {}

    public func credentials(for account: String) -> S3Credentials? { lock.withLock { items[account] } }
    public func save(_ credentials: S3Credentials, for account: String) throws { lock.withLock { items[account] = credentials } }
    public func delete(account: String) { lock.withLock { items[account] = nil } }
}

/// The user's login Keychain: one generic password item, the access key as its account
/// attribute's companion and the secret key as its protected data.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "com.simpleraw.backup") {
        self.service = service
    }

    public func credentials(for account: String) -> S3Credentials? {
        var result: CFTypeRef?
        let query = baseQuery(account).merging([
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 }
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let secret = (item[kSecValueData as String] as? Data).flatMap({ String(data: $0, encoding: .utf8) }),
              let accessKey = item[kSecAttrGeneric as String] as? Data
        else { return nil }
        return S3Credentials(accessKey: String(decoding: accessKey, as: UTF8.self), secretKey: secret)
    }

    /// Updates the item in place when there is one: deleting it first would lose the keys for
    /// good if the write that follows failed.
    public func save(_ credentials: S3Credentials, for account: String) throws {
        let values: [String: Any] = [
            kSecAttrGeneric as String: Data(credentials.accessKey.utf8),
            kSecValueData as String: Data(credentials.secretKey.utf8),
        ]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let item = baseQuery(account).merging(values) { $1 }
                .merging([kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)",
            ])
        }
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
