import Foundation
import Testing
@testable import Backup

@Suite struct S3AddressingTests {
    let configuration = S3Configuration(endpoint: URL(string: "http://localhost:19000")!, region: "us-east-1", bucket: "photos", prefix: "simpleraw")

    /// Path-style: the bucket is in the path, which every S3-compatible service accepts.
    @Test func objectsLiveUnderTheBucketAndThePrefix() {
        let url = configuration.url(forKey: "Originals/2026/R 1.DNG")
        #expect(url.absoluteString == "http://localhost:19000/photos/simpleraw/Originals/2026/R%201.DNG")
    }

    @Test func anEmptyPrefixAddsNothing() {
        var bare = configuration
        bare.prefix = ""
        #expect(bare.url(forKey: "catalog.sqlite").absoluteString == "http://localhost:19000/photos/catalog.sqlite")
        #expect(bare.fullKey("a/b") == "a/b" && configuration.fullKey("a/b") == "simpleraw/a/b")
    }

    @Test func aPrefixMaySpellItsSlashesAnyWay() {
        var sloppy = configuration
        sloppy.prefix = "/simpleraw/"
        #expect(sloppy.fullKey("a") == "simpleraw/a")
    }
}

@Suite struct S3ResponseParsingTests {
    @Test func readsAListingAndItsContinuationToken() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult><Name>photos</Name><IsTruncated>true</IsTruncated>
        <NextContinuationToken>abc==</NextContinuationToken>
        <Contents><Key>simpleraw/Originals/a.DNG</Key><Size>33374940</Size><ETag>&quot;9b2cf5&quot;</ETag></Contents>
        <Contents><Key>simpleraw/catalog.sqlite</Key><Size>4096</Size><ETag>&quot;77aa-2&quot;</ETag></Contents>
        </ListBucketResult>
        """
        let page = try S3XML.listing(from: Data(xml.utf8))
        #expect(page.objects == [
            S3Object(key: "simpleraw/Originals/a.DNG", size: 33_374_940, etag: "9b2cf5"),
            S3Object(key: "simpleraw/catalog.sqlite", size: 4096, etag: "77aa-2"),
        ])
        #expect(page.continuationToken == "abc==")
    }

    @Test func theLastPageHasNoToken() throws {
        let xml = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        let page = try S3XML.listing(from: Data(xml.utf8))
        #expect(page.objects.isEmpty && page.continuationToken == nil)
    }

    @Test func readsTheUploadIdOfAMultipartUpload() throws {
        let xml = "<InitiateMultipartUploadResult><Bucket>photos</Bucket><Key>k</Key><UploadId>VXBsb2Fk</UploadId></InitiateMultipartUploadResult>"
        #expect(try S3XML.value(of: "UploadId", in: Data(xml.utf8)) == "VXBsb2Fk")
    }

    /// It used to be "S3 error 0".
    @Test func anAnswerWithoutWhatWasAskedForSaysWhatIsMissing() {
        let xml = "<InitiateMultipartUploadResult><Bucket>photos</Bucket></InitiateMultipartUploadResult>"
        let error = #expect(throws: S3ClientError.missingElement("UploadId")) { try S3XML.value(of: "UploadId", in: Data(xml.utf8)) }
        #expect(error?.localizedDescription.contains("UploadId") == true)
        #expect(error?.localizedDescription.contains("S3 error 0") == false)
    }

    @Test func errorsSayWhatTheServerSaid() {
        let xml = "<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message></Error>"
        let error = S3Error(status: 404, body: Data(xml.utf8))
        #expect(error.code == "NoSuchBucket")
        #expect(error.localizedDescription.contains("bucket does not exist"))
    }

    @Test func writesTheManifestThatCompletesAMultipartUpload() {
        let body = S3XML.completeMultipartUpload(etags: ["aaa", "bbb"])
        #expect(body == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"aaa\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"bbb\"</ETag></Part></CompleteMultipartUpload>")
    }
}

/// Against a real S3 server. Skipped unless `SIMPLERAW_S3_ENDPOINT` says where it is:
/// `make test-s3` starts MinIO in Docker, runs these, and stops it.
@Suite(.enabled(if: S3TestServer.configuration != nil, "No S3 server: run `make test-s3`"), .serialized)
struct S3ClientIntegrationTests {
    let client: S3Client
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-s3-\(UUID().uuidString)")

    init() async throws {
        client = try #require(S3TestServer.client(prefix: "client-tests-\(UUID().uuidString)"))
        try await client.createBucketIfNeeded()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(named name: String, bytes: Int) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for index in stride(from: 0, to: buffer.count, by: 4093) { buffer[index] = UInt8(truncatingIfNeeded: index / 4093) }
        }
        try data.write(to: url)
        return url
    }

    @Test func aSmallFileGoesUpAndComesBackIdentical() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try file(named: "small.bin", bytes: 200_000)
        try await client.put("Originals/2026/small file.bin", file: source)

        let object = try #require(try await client.head("Originals/2026/small file.bin"))
        #expect(object.size == 200_000)

        let copy = folder.appendingPathComponent("copy.bin")
        try await client.get("Originals/2026/small file.bin", to: copy)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
    }

    @Test func aLargeFileGoesUpInPartsAndComesBackIdentical() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // Three parts with the test part size below.
        let source = try file(named: "large.bin", bytes: 12_500_000)
        let chunked = client.with(partSize: 5 * 1024 * 1024)
        try await chunked.put("large.bin", file: source)
        #expect(try await client.head("large.bin")?.size == 12_500_000)

        let copy = folder.appendingPathComponent("large-copy.bin")
        try await client.get("large.bin", to: copy)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
    }

    @Test func aMissingObjectIsNilNotAnError() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try await client.head("nope.bin") == nil)
    }

    @Test func listingWalksThroughEveryPage() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 1...5 { try await client.put("list/\(index).txt", data: Data("x".utf8)) }
        let keys = try await client.with(pageSize: 2).list(prefix: "list/").map(\.key).sorted()
        #expect(keys == (1...5).map { "list/\($0).txt" })
    }

    /// The bucket is the user's to create, with the options they want (region, versioning,
    /// lock): the app says it is not there, and does not make one in their place.
    @Test func aBucketThatDoesNotExistIsSaidSoAndNotCreated() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "simpleraw-absent-\(UUID().uuidString.lowercased().prefix(8))"
        let stranger = try #require(S3TestServer.client(prefix: "x", bucket: name))
        await #expect(throws: S3ClientError.noSuchBucket(name)) { try await stranger.list() }
        await #expect(throws: S3ClientError.noSuchBucket(name)) { try await stranger.put("a.txt", data: Data("x".utf8)) }
        await #expect(throws: S3ClientError.noSuchBucket(name)) { try await stranger.list() }
    }

    @Test func wrongKeysAreRefused() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let intruder = try #require(S3TestServer.client(prefix: "x", secretKey: "not-the-secret"))
        await #expect(throws: S3Error.self) { try await intruder.put("x.txt", data: Data("x".utf8)) }
    }
}

enum S3TestServer {
    static var configuration: S3Configuration? {
        guard let endpoint = ProcessInfo.processInfo.environment["SIMPLERAW_S3_ENDPOINT"].flatMap(URL.init(string:)) else { return nil }
        return S3Configuration(endpoint: endpoint, region: "us-east-1", bucket: "simpleraw-tests", prefix: "")
    }

    static func client(prefix: String, secretKey: String? = nil, bucket: String? = nil) -> S3Client? {
        guard var configuration else { return nil }
        configuration.prefix = prefix
        if let bucket { configuration.bucket = bucket }
        let environment = ProcessInfo.processInfo.environment
        return S3Client(configuration: configuration, credentials: S3Credentials(
            accessKey: environment["SIMPLERAW_S3_ACCESS_KEY"] ?? "simpleraw",
            secretKey: secretKey ?? environment["SIMPLERAW_S3_SECRET_KEY"] ?? "simpleraw-secret"
        ))
    }
}
