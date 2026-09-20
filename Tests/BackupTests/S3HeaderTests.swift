import Foundation
import Testing
@testable import Backup

/// Header names have no case in HTTP, and HTTP/2 sends them in lowercase: what the client
/// reads must not depend on how a server spells them.
@Suite struct S3HeaderTests {
    /// A server that accepts a multipart upload and names its parts `etag-1`, `etag-2`…
    private func multipartServer(etagHeader: String = "ETag", etag: @escaping @Sendable (Int) -> String = { "\"etag-\($0)\"" }) -> StubServer {
        StubServer { request in
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch request.method {
            case "POST" where query.contains { $0.name == "uploads" }:
                return .xml("<InitiateMultipartUploadResult><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>")
            case "PUT":
                let part = query.first { $0.name == "partNumber" }.flatMap { Int($0.value ?? "") } ?? 0
                return StubServer.Response(headers: [etagHeader: etag(part)])
            case "DELETE":
                return StubServer.Response(status: 204)
            default:
                return .xml("<CompleteMultipartUploadResult><Key>k</Key></CompleteMultipartUploadResult>")
            }
        }
    }

    private func file(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-parts-\(UUID().uuidString)")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test(arguments: ["ETag", "etag", "ETAG", "Etag"])
    func thePartsOfAnUploadAreNamedHoweverTheServerSpellsTheHeader(header: String) async throws {
        let server = multipartServer(etagHeader: header)
        let source = try file(bytes: 2500)
        defer { try? FileManager.default.removeItem(at: source) }

        try await server.client().with(partSize: 1000).put("big.bin", file: source)

        let manifest = try #require(server.requests.last { $0.method == "POST" })
        #expect(String(decoding: manifest.body, as: UTF8.self) == S3XML.completeMultipartUpload(etags: ["etag-1", "etag-2", "etag-3"]))
    }

    /// Without it the upload cannot be completed: better to know at the first part than
    /// after sending the whole file.
    @Test func aPartWithoutAnETagStopsTheUploadAtOnce() async throws {
        let server = multipartServer(etag: { _ in "\"\"" })
        let source = try file(bytes: 2500)
        defer { try? FileManager.default.removeItem(at: source) }

        await #expect(throws: S3ClientError.missingETag(part: 1)) {
            try await server.client().with(partSize: 1000).put("big.bin", file: source)
        }
        #expect(server.requests.filter { $0.method == "PUT" }.count == 1)
        // Parts of an abandoned upload are billed until it is aborted.
        #expect(server.requests.last?.method == "DELETE")
    }

    @Test(arguments: ["a\"</ETag><ETag>b", "a&b", "a<b", "a b", "\u{e9}tag"])
    func anETagThatIsNotOneIsRefused(etag: String) async throws {
        let server = multipartServer(etag: { _ in etag })
        let source = try file(bytes: 1500)
        defer { try? FileManager.default.removeItem(at: source) }

        await #expect(throws: S3ClientError.invalidETag) {
            try await server.client().with(partSize: 1000).put("big.bin", file: source)
        }
        #expect(!server.requests.contains { $0.method == "POST" && !$0.body.isEmpty })
    }

    /// The fingerprint travels as metadata of the object, inside the signature: it cannot be
    /// changed on the way, and "Verify Backup" reads it back with a HEAD.
    @Test func everyUploadCarriesASignedFingerprint() async throws {
        let server = multipartServer()
        let source = try file(bytes: 2500)
        defer { try? FileManager.default.removeItem(at: source) }
        let expected = BackupHash.sha256(of: Data(repeating: 7, count: 2500))

        try await server.client().put("small.bin", file: source)
        try await server.client().put("data.bin", data: Data(repeating: 7, count: 2500))
        try await server.client().with(partSize: 1000).put("big.bin", file: source)

        let carriers = server.requests.filter { $0.header("x-amz-meta-sha256") != nil }
        #expect(carriers.map(\.method) == ["PUT", "PUT", "POST"])
        for request in carriers {
            #expect(request.header("x-amz-meta-sha256") == expected)
            #expect(request.header("Authorization")?.contains("x-amz-meta-sha256") == true)
        }
    }

    @Test func headReadsTheFingerprintIfItLooksLikeOne() async throws {
        let fingerprint = BackupHash.sha256(of: Data("aaa".utf8))
        let server = StubServer { request in
            StubServer.Response(headers: ["Content-Length": "3", "ETag": "\"e\"", "x-amz-meta-sha256": request.url.lastPathComponent == "a.DNG" ? fingerprint : "<script>"])
        }
        #expect(try await server.client().head("a.DNG")?.sha256 == fingerprint)
        #expect(try await server.client().head("b.DNG")?.sha256 == nil)
    }

    /// Belt and braces: the manifest escapes what it is given, validated or not.
    @Test func theManifestEscapesWhatItIsGiven() {
        let body = S3XML.completeMultipartUpload(etags: ["a\"</ETag>&<x>"])
        #expect(body == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"a&quot;&lt;/ETag&gt;&amp;&lt;x&gt;\"</ETag></Part></CompleteMultipartUpload>")
    }

    @Test(arguments: [["content-length": "1234", "etag": "\"abc\""], ["CONTENT-LENGTH": "1234", "ETAG": "\"abc\""]])
    func headReadsSizeAndETagWhateverTheirCase(headers: [String: String]) async throws {
        let server = StubServer { _ in StubServer.Response(headers: headers) }
        let object = try #require(try await server.client().head("a.DNG"))
        #expect(object.size == 1234 && object.etag == "abc")
    }
}
