import Foundation
import Testing
@testable import Backup

/// How the client talks to a server it does not trust: no redirection followed, nothing kept
/// on disk, and answers of a bounded size.
@Suite struct S3TransportTests {
    /// A 307 would send the body again, a photo or the catalog, wherever the server says.
    @Test(arguments: [301, 302, 307, 308])
    func aRedirectionIsRefusedAndNeverFollowed(status: Int) async throws {
        let elsewhere = StubServer()
        let server = StubServer { _ in .redirect(to: elsewhere.endpoint.appendingPathComponent("photos/a.txt"), status: status) }

        let error = await #expect(throws: S3Error.self) {
            try await server.client().put("a.txt", data: Data("photo".utf8))
        }
        #expect(server.requests.count == 1)
        #expect(elsewhere.requests.isEmpty)
        #expect(error?.status == status)
        #expect(error?.localizedDescription.contains(elsewhere.host) == true)
        #expect(error?.localizedDescription.contains("endpoint") == true)
    }

    @Test func aRedirectedDownloadWritesNothing() async throws {
        let elsewhere = StubServer { _ in StubServer.Response(body: Data("not the photo".utf8)) }
        let server = StubServer { _ in .redirect(to: elsewhere.endpoint.appendingPathComponent("photos/a.txt")) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-redirect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: S3Error.self) { try await server.client().get("a.txt", to: destination) }
        #expect(elsewhere.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// Listings are every file name of the library: they must not end up in a cache on disk,
    /// and a backup has no use for cookies.
    @Test func theSessionKeepsNothingAndDoesNotWaitForever() {
        let configuration = S3Transport.configuration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(configuration.timeoutIntervalForResource <= 3600)
        #expect(configuration.waitsForConnectivity)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    @Test func anAnswerLargerThanTheLimitIsRefused() async throws {
        let page = "<ListBucketResult>" + String(repeating: "<Contents><Key>k</Key><Size>1</Size><ETag>e</ETag></Contents>", count: 200) + "</ListBucketResult>"
        let server = StubServer { _ in .xml(page) }
        await #expect(throws: S3ClientError.responseTooLarge(limit: 1024)) {
            try await server.client().with(responseLimit: 1024).list()
        }
        #expect(try await server.client().list().count == 200)
    }
}

@Suite struct S3ListingTests {
    /// Keys come back without the configuration's prefix. One that does not carry it is not
    /// ours, and cutting its first characters off would make it look like it is.
    @Test func keysOutsideOfThePrefixAreLeftOut() async throws {
        let server = StubServer { _ in .xml("""
            <ListBucketResult><IsTruncated>false</IsTruncated>
            <Contents><Key>simpleraw/Originals/a.DNG</Key><Size>3</Size><ETag>e</ETag></Contents>
            <Contents><Key>elsewhere/Originals/b.DNG</Key><Size>3</Size><ETag>e</ETag></Contents>
            <Contents><Key>simplerawOriginals/c.DNG</Key><Size>3</Size><ETag>e</ETag></Contents>
            <Contents><Key>x</Key><Size>3</Size><ETag>e</ETag></Contents>
            </ListBucketResult>
            """)
        }
        #expect(try await server.client(prefix: "simpleraw").list().map(\.key) == ["Originals/a.DNG"])
    }
}

/// What goes wrong is said in words a photographer can act on.
@Suite struct S3ClientErrorTests {
    private let noSuchBucket = "<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message><BucketName>photos</BucketName></Error>"

    @Test func aBucketThatDoesNotExistIsNamed() async throws {
        let server = StubServer { [noSuchBucket] _ in .xml(noSuchBucket, status: 404) }
        let error = await #expect(throws: S3ClientError.noSuchBucket("photos")) { try await server.client().list() }
        #expect(error?.localizedDescription.contains("The bucket “photos” does not exist") == true)
        await #expect(throws: S3ClientError.noSuchBucket("photos")) { try await server.client().put("a.txt", data: Data("x".utf8)) }
        // Nothing but what was asked: no attempt at creating the bucket.
        #expect(server.requests.map(\.method) == ["GET", "PUT"])
    }

    @Test func anUploadThatStartsWithoutAnIdentifierSaysSo() async throws {
        let server = StubServer { _ in .xml("<InitiateMultipartUploadResult><Bucket>photos</Bucket></InitiateMultipartUploadResult>") }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-parts-\(UUID().uuidString)")
        try Data(repeating: 7, count: 2500).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: S3ClientError.missingElement("UploadId")) {
            try await server.client().with(partSize: 1000).put("big.bin", file: source)
        }
    }

    /// A download replaces a file, never a folder.
    @Test func aDownloadOntoAFolderLeavesItAlone() async throws {
        let server = StubServer { _ in StubServer.Response(body: Data("photo".utf8)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: folder.appendingPathComponent("kept.txt"))
        defer { try? FileManager.default.removeItem(at: folder) }

        let error = await #expect(throws: S3ClientError.self) { try await server.client().get("a.DNG", to: folder) }
        #expect(error == .destinationIsAFolder(folder.path))
        #expect(try String(contentsOf: folder.appendingPathComponent("kept.txt"), encoding: .utf8) == "kept")
    }

    @Test func everyProblemExplainsItself() {
        let problems: [S3ClientError] = [
            .responseTooLarge(limit: 1), .unsafeXML, .missingETag(part: 1), .invalidETag, .invalidURL,
            .missingElement("UploadId"), .noSuchBucket("photos"), .destinationIsAFolder("/tmp/x"), .notHTTP,
        ]
        for problem in problems { #expect(problem.errorDescription?.isEmpty == false) }
    }
}

/// S3 answers in plain XML. Anything cleverer than that is refused.
@Suite struct S3XMLHardeningTests {
    @Test(arguments: [
        "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;&a;&a;\">]><r><UploadId>&b;</UploadId></r>",
        "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><r><UploadId>&x;</UploadId></r>",
        "<!DOCTYPE r><r><UploadId>abc</UploadId></r>",
        "<!DOCTYPE r SYSTEM \"http://example.test/r.dtd\"><r><UploadId>abc</UploadId></r>",
    ])
    func aDocumentTypeOrAnEntityIsRefused(xml: String) {
        #expect(throws: S3ClientError.unsafeXML) { try S3XML.value(of: "UploadId", in: Data(xml.utf8)) }
        #expect(throws: S3ClientError.unsafeXML) { try S3XML.listing(from: Data(xml.utf8)) }
    }

    /// The same document in UTF-16 hides "<!DOCTYPE" from a search of the bytes.
    @Test func aDeclarationInAnotherEncodingIsRefusedToo() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE r [<!ENTITY a \"aaaa\">]><r><UploadId>&a;</UploadId></r>"
        let data = try #require(xml.data(using: .utf16))
        #expect(throws: (any Error).self) { try S3XML.value(of: "UploadId", in: data) }
    }

    @Test func anElementOfUnreasonableLengthIsRefused() {
        let xml = "<r><UploadId>\(String(repeating: "a", count: S3XML.maximumTextLength + 1))</UploadId></r>"
        #expect(throws: S3ClientError.unsafeXML) { try S3XML.value(of: "UploadId", in: Data(xml.utf8)) }
        let fine = "<r><UploadId>\(String(repeating: "a", count: S3XML.maximumTextLength))</UploadId></r>"
        #expect(throws: Never.self) { try S3XML.value(of: "UploadId", in: Data(fine.utf8)) }
    }
}
