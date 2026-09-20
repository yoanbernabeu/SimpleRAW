import CryptoKit
import Foundation

public struct S3Credentials: Equatable, Sendable {
    public let accessKey: String
    public let secretKey: String

    public init(accessKey: String, secretKey: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
    }
}

/// However credentials get printed, interpolated, dumped or logged, the secret does not
/// come along. The access key does: it is an identifier, and says which key is in use.
extension S3Credentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "S3Credentials(accessKey: \(accessKey), secretKey: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["accessKey": accessKey, "secretKey": "<redacted>"], displayStyle: .struct)
    }
}

/// AWS Signature Version 4, for S3: what every S3-compatible service checks requests with.
/// Pure: given the same request, keys and date, it always produces the same headers, which
/// is how it is tested against the worked examples of the AWS documentation.
struct SigV4Signer: Sendable {
    let credentials: S3Credentials
    let region: String

    enum SigningError: Error, LocalizedError, Equatable {
        case noHost

        var errorDescription: String? { "The request names no server, so it cannot be signed and was not sent." }
    }

    /// Adds `Host`, `x-amz-date`, `x-amz-content-sha256` and `Authorization` to the request.
    /// - Parameter payloadHash: SHA-256 of the body, in hexadecimal.
    /// - Throws: rather than leaving the request as it is, which would send it unsigned.
    func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) throws {
        guard let url = request.url, let host = url.host, !host.isEmpty else { throw SigningError.noHost }
        let stamp = Self.timestamp(date)
        let day = String(stamp.prefix(8))
        let port = url.port.map { ":\($0)" } ?? ""
        request.setValue(host + port, forHTTPHeaderField: "Host")
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Every header present is signed, lowercased and in order.
        let headers = (request.allHTTPHeaderFields ?? [:])
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            Self.canonicalPath(of: url),
            Self.canonicalQuery(of: url),
            headers.map { "\($0.0):\($0.1)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")

        var key = Data("AWS4\(credentials.secretKey)".utf8)
        for part in [day, region, "s3", "aws4_request"] {
            key = Self.hmac(part, key: key)
        }
        let signature = Self.hmac(stringToSign, key: key).map { String(format: "%02x", $0) }.joined()
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    // MARK: - Canonical forms

    /// Unreserved characters stay; everything else is percent-encoded. Slashes too, in queries.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func canonicalPath(of url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0) }
            .joined(separator: "/")
    }

    static func canonicalQuery(of url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items
            .map { (encode($0.name), encode($0.value ?? "")) }
            .sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ message: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
