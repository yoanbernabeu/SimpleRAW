import Foundation

/// Checks the endpoint a user typed, before it is saved or used.
public enum S3Endpoint {
    public enum Problem: Error, LocalizedError, Equatable {
        case empty
        case notAWebAddress
        case containsCredentials
        case hasQueryOrFragment

        public var errorDescription: String? {
            switch self {
            case .empty: "Enter the address of your storage, such as https://s3.eu-west-3.amazonaws.com."
            case .notAWebAddress: "The address must start with https:// (or http:// on a local network) and name a server."
            case .containsCredentials: "Do not put keys in the address: they go in the two fields below, and are kept in your Keychain."
            case .hasQueryOrFragment: "The address must not contain a ? or a #."
            }
        }
    }

    public struct Validated: Equatable, Sendable {
        public let url: URL
        /// Plain http: photos and catalog travel in clear text. Allowed, never silent.
        public let isInsecure: Bool
    }

    public static func validate(_ text: String) throws -> Validated {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Problem.empty }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = components.host, !host.isEmpty else {
            throw Problem.notAWebAddress
        }
        // Keys in a URL would be written in clear text to the settings file.
        guard components.user == nil, components.password == nil else { throw Problem.containsCredentials }
        guard components.query == nil, components.fragment == nil else { throw Problem.hasQueryOrFragment }
        guard let url = components.url else { throw Problem.notAWebAddress }
        return Validated(url: url, isInsecure: scheme == "http")
    }
}

/// Checks the other names of a configuration: they end up in URLs, in keys and in the
/// signature, whether the user typed them or a settings file said them.
public enum S3Naming {
    public enum Problem: Error, LocalizedError, Equatable {
        case emptyBucket
        case invalidBucket
        case invalidPrefix
        case invalidRegion

        public var errorDescription: String? {
            switch self {
            case .emptyBucket: "Enter the name of the bucket your photos go to."
            case .invalidBucket: "A bucket name is 3 to 63 lowercase letters, digits, dots and dashes, and starts and ends with a letter or a digit."
            case .invalidPrefix: "The folder must be a plain path such as backups/simpleraw, without . or .. in it."
            case .invalidRegion: "A region is a short word such as eu-west-3."
            }
        }
    }

    private static let lowercaseAndDigits = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    private static let regionCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")

    /// The rules of S3 itself, `^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$` and no `..`: the bucket
    /// is a component of every URL, and must not be able to name another place.
    public static func bucket(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Problem.emptyBucket }
        let scalars = Array(name.unicodeScalars)
        let inner = lowercaseAndDigits.union(CharacterSet(charactersIn: ".-"))
        guard (3...63).contains(scalars.count), scalars.allSatisfy(inner.contains),
              let first = scalars.first, let last = scalars.last, lowercaseAndDigits.contains(first), lowercaseAndDigits.contains(last),
              !name.contains("..") else { throw Problem.invalidBucket }
        return name
    }

    /// One spelling for a folder of the bucket: no slash at either end, none doubled. A `.`
    /// or a `..` is refused rather than resolved: servers do not agree on what they mean.
    public static func prefix(_ text: String) throws -> String {
        let segments = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").map(String.init)
        guard segments.allSatisfy({ segment in
            segment != "." && segment != ".." && segment.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        }) else { throw Problem.invalidPrefix }
        let prefix = segments.joined(separator: "/")
        // Keys stop at 1024 bytes, and the library's own paths need most of them.
        guard prefix.utf8.count <= 512 else { throw Problem.invalidPrefix }
        return prefix
    }

    /// The region is part of what is signed. Left empty it is `us-east-1`, which is what S3
    /// means by default and what servers without regions expect.
    public static func region(_ text: String) throws -> String {
        let region = text.trimmingCharacters(in: .whitespaces)
        guard !region.isEmpty else { return "us-east-1" }
        guard region.unicodeScalars.count <= 64, region.unicodeScalars.allSatisfy(regionCharacters.contains) else { throw Problem.invalidRegion }
        return region
    }
}

extension S3Configuration {
    /// The one way in for what a user typed.
    /// - Throws: `S3Endpoint.Problem` or `S3Naming.Problem`, which explain themselves.
    public static func validated(endpoint: String, region: String, bucket: String, prefix: String) throws -> S3Configuration {
        S3Configuration(
            endpoint: try S3Endpoint.validate(endpoint).url,
            region: try S3Naming.region(region),
            bucket: try S3Naming.bucket(bucket),
            prefix: try S3Naming.prefix(prefix)
        )
    }

    /// The same checks on a configuration that was decoded: a settings file is not trusted
    /// more than a text field.
    public func validated() throws -> S3Configuration {
        try Self.validated(endpoint: endpoint.absoluteString, region: region, bucket: bucket, prefix: prefix)
    }
}
