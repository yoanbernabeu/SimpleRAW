import Foundation
@testable import Backup

/// An S3 server that lives in the process: a `URLProtocol` answers in place of the network.
/// Each one has a host of its own, so that tests can run side by side, and nothing ever
/// leaves the machine: every `.test` host is claimed, known or not.
final class StubServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        static func xml(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/xml"], body: Data(text.utf8))
        }

        static func redirect(to url: URL, status: Int = 307) -> Response {
            Response(status: status, headers: ["Location": url.absoluteString])
        }
    }

    let host = "\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var recorded: [Request] = []
    private let respond: @Sendable (Request) -> Response

    init(respond: @escaping @Sendable (Request) -> Response = { _ in Response() }) {
        self.respond = respond
        StubProtocol.register(self)
    }

    deinit { StubProtocol.unregister(host) }

    var endpoint: URL { URL(string: "https://\(host)")! }
    var requests: [Request] { lock.withLock { recorded } }

    func client(prefix: String = "") -> S3Client {
        S3Client(
            configuration: S3Configuration(endpoint: endpoint, region: "us-east-1", bucket: "photos", prefix: prefix),
            credentials: S3Credentials(accessKey: "AKIDEXAMPLE", secretKey: "stub-secret"),
            session: S3Transport.session(protocolClasses: [StubProtocol.self])
        )
    }

    fileprivate func answer(_ request: Request) -> Response {
        lock.withLock { recorded.append(request) }
        return respond(request)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    // Weakly would be nicer, but a server unregisters itself when it goes away.
    static func register(_ server: StubServer) { lock.withLock { servers[server.host] = server } }
    static func unregister(_ host: String) { lock.withLock { servers[host] = nil } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = Self.lock.withLock({ Self.servers[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let answer = server.answer(StubServer.Request(
            method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request)
        ))
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        if (300..<400).contains(answer.status), let location = answer.headers["Location"].flatMap(URL.init(string:)) {
            var next = request
            next.url = location
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The loading system hands a protocol the body as a stream, whatever it was given.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
