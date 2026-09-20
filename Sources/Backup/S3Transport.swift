import Foundation

/// The session every S3 request goes through. Not `URLSession.shared`: that one caches
/// answers on disk (a listing is every file name of the library), keeps cookies, follows
/// redirections and waits as long as it takes.
enum S3Transport {
    /// One session for the process: a session keeps its delegate alive until it is
    /// invalidated, and a client is made for every run.
    static let shared = session()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        // A laptop that wakes up without a network waits for it rather than failing the run,
        // but not for days: `timeoutIntervalForResource` is a week unless told otherwise.
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        return configuration
    }

    /// - Parameter protocolClasses: how tests answer in place of the network.
    static func session(protocolClasses: [AnyClass] = []) -> URLSession {
        let configuration = configuration()
        configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        return URLSession(configuration: configuration, delegate: RedirectionRefuser(), delegateQueue: nil)
    }
}

/// A 307 or a 308 makes `URLSession` send the body again, a photo or the catalog, to wherever
/// the server says. Nothing is followed: the 3xx comes back as the answer, and becomes an error.
private final class RedirectionRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
