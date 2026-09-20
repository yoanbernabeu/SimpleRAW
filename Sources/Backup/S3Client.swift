import CryptoKit
import Foundation

/// Where to back up: any S3-compatible service.
public struct S3Configuration: Codable, Equatable, Sendable {
    public var endpoint: URL
    public var region: String
    public var bucket: String
    /// A folder inside the bucket, so that a bucket can hold something else too.
    public var prefix: String

    public init(endpoint: URL, region: String, bucket: String, prefix: String = "") {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.prefix = prefix
    }

    /// The key as the bucket knows it, prefix included.
    func fullKey(_ key: String) -> String {
        let folder = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty ? key : "\(folder)/\(key)"
    }

    /// Path-style addressing (`endpoint/bucket/key`): the one form every S3-compatible
    /// service accepts, custom endpoints and local servers included.
    func url(forKey key: String) -> URL {
        bucketURL.appendingPathComponent(fullKey(key))
    }

    var bucketURL: URL { endpoint.appendingPathComponent(bucket) }
}

public struct S3Object: Equatable, Sendable {
    public let key: String
    public let size: Int
    public let etag: String
    /// The SHA-256 the object was uploaded with. Only a `head` knows it: a listing does not
    /// carry metadata. `nil` too for what was uploaded before fingerprints were.
    public let sha256: String?

    public init(key: String, size: Int, etag: String, sha256: String? = nil) {
        self.key = key
        self.size = size
        self.etag = etag
        self.sha256 = sha256
    }
}

public struct S3Error: Error, LocalizedError, Equatable {
    public let status: Int
    public let code: String?
    public let message: String?

    /// Only `Code` and `Message` are read. An error answer also echoes the access key and the
    /// strings that were signed (`AWSAccessKeyId`, `StringToSign`, `CanonicalRequest`): those
    /// are never repeated.
    init(status: Int, body: Data) {
        self.status = status
        code = (try? S3XML.value(of: "Code", in: body)).map { Self.displayable($0, limit: 64) }
        message = (try? S3XML.value(of: "Message", in: body)).map { Self.displayable($0, limit: 200) }
    }

    /// The server's words end up on screen: on one line, without anything that steers a
    /// terminal or reverses the text, and short.
    static func displayable(_ text: String, limit: Int) -> String {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: " "
            default: scalar
            }
        }))
        let words = visible.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return words.count > limit ? words.prefix(limit) + "…" : words
    }

    /// A redirection is never followed: the body, a photo or the catalog, would be sent again
    /// to wherever the server says.
    init(status: Int, redirectedTo location: String?) {
        self.status = status
        code = "Redirect"
        let host = location.flatMap { URLComponents(string: $0)?.host }.map { " to \($0)" } ?? ""
        message = "The server redirects\(host), and a redirection is never followed. Check the endpoint and the region."
    }

    public var errorDescription: String? {
        "S3 error \(status)" + (code.map { " (\($0))" } ?? "") + (message.map { ": \($0)" } ?? "")
    }
}

/// What went wrong on our side of the conversation, or in an answer that cannot be trusted.
public enum S3ClientError: Error, LocalizedError, Equatable {
    case responseTooLarge(limit: Int)
    case unsafeXML
    case missingETag(part: Int)
    case invalidETag
    case invalidURL
    case missingElement(String)
    case noSuchBucket(String)
    case destinationIsAFolder(String)
    case notHTTP

    public var errorDescription: String? {
        switch self {
        case .responseTooLarge(let limit): "The server sent an answer of more than \(limit) bytes where a short one was expected."
        case .unsafeXML: "The server sent an answer that is not the plain XML S3 speaks."
        case .missingETag(let part): "The server did not name part \(part) of the upload (no ETag), so the upload cannot be completed."
        case .missingElement(let name): "The server's answer lacks the \(name) it was asked for. Is this an S3-compatible service?"
        case .noSuchBucket(let name): "The bucket “\(name)” does not exist on this server. Create it with your storage provider, or check its name and the region."
        case .destinationIsAFolder(let path): "\(path) is a folder: a download replaces a file, never a folder."
        case .notHTTP: "The server did not answer over HTTP."
        case .invalidURL: "The endpoint, the bucket and the key do not make an address."
        case .invalidETag: "The server named a part of the upload in a way no S3 service does."
        }
    }
}

/// The few S3 operations a backup needs, over `URLSession`, signed with SigV4.
public struct S3Client: Sendable {
    public let configuration: S3Configuration
    private let signer: SigV4Signer
    private let session: URLSession
    /// Files larger than a part go up in parts, so that a failure costs one part, not the file.
    private var partSize = 16 * 1024 * 1024
    private var pageSize = 1000
    /// Answers other than objects are small: a page of 1000 keys is about 500 KB. A server
    /// does not get to fill the memory.
    private var responseLimit = 5 * 1024 * 1024

    public init(configuration: S3Configuration, credentials: S3Credentials) {
        self.init(configuration: configuration, credentials: credentials, session: S3Transport.shared)
    }

    /// - Parameter session: one made by `S3Transport`, which tests point at a server of their own.
    init(configuration: S3Configuration, credentials: S3Credentials, session: URLSession) {
        self.configuration = configuration
        signer = SigV4Signer(credentials: credentials, region: configuration.region)
        self.session = session
    }

    func with(partSize: Int) -> S3Client {
        var copy = self
        copy.partSize = partSize
        return copy
    }

    func with(responseLimit: Int) -> S3Client {
        var copy = self
        copy.responseLimit = responseLimit
        return copy
    }

    func with(pageSize: Int) -> S3Client {
        var copy = self
        copy.pageSize = pageSize
        return copy
    }

    // MARK: - Bucket

    /// For tests against a throwaway server. The app never makes a bucket in the user's
    /// place: region, versioning and lock are theirs to choose.
    func createBucketIfNeeded() async throws {
        let (_, response) = try await send("HEAD", configuration.bucketURL, accepting: [200, 404, 403])
        guard response.statusCode == 404 else { return }
        try await send("PUT", configuration.bucketURL, accepting: [200, 409])
    }

    // MARK: - Objects

    /// The ETag of an object is not a hash one can rely on (parts, encryption). Its SHA-256
    /// goes up as metadata instead, signed with the rest, for a later `head` to read back.
    static let fingerprintHeader = "x-amz-meta-sha256"

    public func put(_ key: String, data: Data) async throws {
        let hash = SigV4Signer.sha256Hex(data)
        try await send("PUT", configuration.url(forKey: key), headers: [Self.fingerprintHeader: hash], body: data, payloadHash: hash)
    }

    /// Small files go up in one request, large ones in parts. Either way every byte is
    /// covered by a SHA-256 the server checks: what arrives is what was sent.
    public func put(_ key: String, file: URL) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > partSize else {
            try await put(key, data: try Data(contentsOf: file, options: .mappedIfSafe))
            return
        }
        let url = configuration.url(forKey: key)
        // Metadata is given when the upload starts: one more read of the file, which is
        // nothing next to sending it.
        let fingerprint = try BackupHash.sha256(of: file)
        let (created, _) = try await send("POST", url, query: [("uploads", "")], headers: [Self.fingerprintHeader: fingerprint])
        let uploadID = try S3XML.value(of: "UploadId", in: created)
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var etags: [String] = []
            while let part = try handle.read(upToCount: partSize), !part.isEmpty {
                let query = [("partNumber", String(etags.count + 1)), ("uploadId", uploadID)]
                let (_, response) = try await send("PUT", url, query: query, body: part)
                // Without the name of a part the upload cannot be completed: better to know
                // now than after sending the whole file.
                let etag = Self.etag(of: response)
                guard !etag.isEmpty else { throw S3ClientError.missingETag(part: etags.count + 1) }
                guard S3XML.isETag(etag) else { throw S3ClientError.invalidETag }
                etags.append(etag)
            }
            let manifest = Data(S3XML.completeMultipartUpload(etags: etags).utf8)
            try await send("POST", url, query: [("uploadId", uploadID)], body: manifest)
        } catch {
            // Parts of an abandoned upload are billed until it is aborted.
            _ = try? await send("DELETE", url, query: [("uploadId", uploadID)], accepting: [204, 404])
            throw error
        }
    }

    /// `nil` when there is no such object.
    public func head(_ key: String) async throws -> S3Object? {
        let (_, response) = try await send("HEAD", configuration.url(forKey: key), accepting: [200, 404])
        guard response.statusCode == 200 else { return nil }
        let size = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) ?? 0
        // Anyone who can write to the bucket chooses this value: it is compared, never shown.
        let fingerprint = response.value(forHTTPHeaderField: Self.fingerprintHeader).flatMap { BackupHash.isSHA256($0) ? $0 : nil }
        return S3Object(key: key, size: size, etag: Self.etag(of: response), sha256: fingerprint)
    }

    /// Header names have no case: `value(forHTTPHeaderField:)` knows, a dictionary does not.
    private static func etag(of response: HTTPURLResponse) -> String {
        (response.value(forHTTPHeaderField: "ETag") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Every object under `prefix`, however many pages that takes. Keys come back without
    /// the configuration's own prefix, the way they were given to `put`.
    public func list(prefix: String = "") async throws -> [S3Object] {
        var objects: [S3Object] = []
        var token: String?
        let own = configuration.fullKey("")
        repeat {
            var query = [("list-type", "2"), ("max-keys", String(pageSize)), ("prefix", configuration.fullKey(prefix))]
            if let token { query.append(("continuation-token", token)) }
            let (body, _) = try await send("GET", configuration.bucketURL, query: query)
            let page = try S3XML.listing(from: body)
            // A key that does not carry the prefix is not ours: cutting its first characters
            // off regardless would make it look like it is.
            objects += page.objects.filter { $0.key.hasPrefix(own) }
                .map { S3Object(key: String($0.key.dropFirst(own.count)), size: $0.size, etag: $0.etag) }
            token = page.continuationToken
        } while token != nil
        return objects
    }

    public func get(_ key: String, to destination: URL) async throws {
        var request = URLRequest(url: configuration.url(forKey: key))
        try signer.sign(&request, payloadHash: SigV4Signer.sha256Hex(Data()))
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response, accepting: [200]) {
            let handle = try? FileHandle(forReadingFrom: temporary)
            defer { try? handle?.close() }
            return (try? handle?.read(upToCount: responseLimit)) ?? Data()
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Replaces a file, never a folder: a download must not be able to delete a directory.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw S3ClientError.destinationIsAFolder(destination.path) }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    // MARK: - Requests

    @discardableResult
    private func send(
        _ method: String, _ url: URL, query: [(String, String)] = [], headers: [String: String] = [:],
        body: Data = Data(), payloadHash: String? = nil, accepting: Set<Int> = [200]
    ) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw S3ClientError.invalidURL }
        if !query.isEmpty {
            // Encoded by hand, the way the signature expects: URLComponents leaves "/" and "+" alone.
            components.percentEncodedQuery = query.map { "\(SigV4Signer.encode($0.0))=\(SigV4Signer.encode($0.1))" }.joined(separator: "&")
        }
        guard let address = components.url else { throw S3ClientError.invalidURL }
        var request = URLRequest(url: address)
        request.httpMethod = method
        // Before signing: every header present is signed.
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        try signer.sign(&request, payloadHash: payloadHash ?? SigV4Signer.sha256Hex(body))

        if method == "PUT" || method == "POST" { request.httpBody = body }

        let (bytes, response) = try await session.bytes(for: request)
        // A HEAD announces the length of the object, and sends nothing.
        if method != "HEAD", response.expectedContentLength > Int64(responseLimit) {
            bytes.task.cancel()
            throw S3ClientError.responseTooLarge(limit: responseLimit)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < responseLimit else {
                bytes.task.cancel()
                throw S3ClientError.responseTooLarge(limit: responseLimit)
            }
            data.append(byte)
        }
        return (data, try check(response, accepting: accepting) { data })
    }

    /// - Parameter body: read only to explain a refusal.
    @discardableResult
    private func check(_ response: URLResponse, accepting: Set<Int>, body: () -> Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw S3ClientError.notHTTP }
        guard !accepting.contains(http.statusCode) else { return http }
        if (300..<400).contains(http.statusCode) {
            throw S3Error(status: http.statusCode, redirectedTo: http.value(forHTTPHeaderField: "Location"))
        }
        let error = S3Error(status: http.statusCode, body: body())
        // The most likely mistake of a first setup deserves better than a status and a code.
        // The bucket is the user's to create, with the options they want: it is not made here.
        guard error.code != "NoSuchBucket" else { throw S3ClientError.noSuchBucket(configuration.bucket) }
        throw error
    }
}

/// The little XML that S3 speaks.
enum S3XML {
    /// A key is at most 1024 bytes; nothing S3 says is longer than a few of those.
    static let maximumTextLength = 4096

    static func listing(from data: Data) throws -> (objects: [S3Object], continuationToken: String?) {
        let reader = Reader()
        try reader.parse(data)
        let objects = reader.records("Contents").map {
            S3Object(key: $0["Key"] ?? "", size: Int($0["Size"] ?? "") ?? 0, etag: ($0["ETag"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return (objects, reader.topLevel["NextContinuationToken"])
    }

    static func value(of element: String, in data: Data) throws -> String {
        let reader = Reader()
        try reader.parse(data)
        guard let value = reader.topLevel[element] else { throw S3ClientError.missingElement(element) }
        return value
    }

    static func completeMultipartUpload(etags: [String]) -> String {
        let parts = etags.enumerated().map { "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\"\(escape($0.element))\"</ETag></Part>" }
        return "<CompleteMultipartUpload>\(parts.joined())</CompleteMultipartUpload>"
    }

    /// What services name a part with: hexadecimal, sometimes Base64, a dash and a count.
    static func isETag(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=._-")
        return !text.isEmpty && text.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Flat reader: text of the root's direct children, and of the children of repeated records.
    private final class Reader: NSObject, XMLParserDelegate {
        private(set) var topLevel: [String: String] = [:]
        private var recordsByName: [String: [[String: String]]] = [:]
        private var path: [String] = []
        private var text = ""
        private var current: [String: String] = [:]

        private var isUnsafe = false

        /// S3 never sends a document type, let alone an entity: a document that has one is
        /// refused whole, rather than trusting the parser to expand it within reason.
        func parse(_ data: Data) throws {
            guard data.range(of: Data("<!DOCTYPE".utf8)) == nil else { throw S3ClientError.unsafeXML }
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            let parsed = parser.parse()
            guard !isUnsafe else { throw S3ClientError.unsafeXML }
            guard parsed else { throw parser.parserError ?? S3ClientError.unsafeXML }
        }

        private func refuse(_ parser: XMLParser) {
            isUnsafe = true
            parser.abortParsing()
        }

        // The search above reads bytes; these see a declaration written in any encoding.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { refuse(parser) }
        func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String, type: String?, defaultValue: String?) { refuse(parser) }
        func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { refuse(parser) }

        func records(_ name: String) -> [[String: String]] { recordsByName[name] ?? [] }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            path.append(name)
            text = ""
            if path.count == 2 { current = [:] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard text.utf8.count + string.utf8.count <= S3XML.maximumTextLength else { return refuse(parser) }
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch path.count {
            case 2:
                if current.isEmpty { topLevel[name] = value } else { recordsByName[name, default: []].append(current) }
            case 3:
                current[name] = value
            default:
                break
            }
            path.removeLast()
            text = ""
        }
    }
}
