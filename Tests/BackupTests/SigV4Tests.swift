import Foundation
import Testing
@testable import Backup

/// The worked examples of the AWS documentation ("Signature Calculations for the
/// Authorization Header"): same keys, same date, same requests, same signatures.
@Suite struct SigV4Tests {
    let signer = SigV4Signer(
        credentials: S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        region: "us-east-1"
    )
    /// 2013-05-24T00:00:00Z
    let date = Date(timeIntervalSince1970: 1_369_353_600)
    let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func signsTheGetObjectExample() throws {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        try signer.sign(&request, payloadHash: emptyHash, date: date)

        #expect(request.value(forHTTPHeaderField: "x-amz-date") == "20130524T000000Z")
        #expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == emptyHash)
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
            + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func signsTheListObjectsExample() throws {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!)
        try signer.sign(&request, payloadHash: emptyHash, date: date)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix(
            "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    /// A request that cannot be signed must not leave unsigned.
    @Test(arguments: ["file:///tmp/a.txt", "/photos/a.txt", "https:///a.txt"])
    func aRequestWithoutAHostIsRefusedRatherThanSentUnsigned(address: String) throws {
        var request = URLRequest(url: try #require(URL(string: address)))
        #expect(throws: SigV4Signer.SigningError.noHost) { try signer.sign(&request, payloadHash: emptyHash, date: date) }
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func queryParametersAreSortedAndEncoded() {
        let canonical = SigV4Signer.canonicalQuery(of: URL(string: "https://h/?prefix=a b/c&list-type=2&delimiter=")!)
        #expect(canonical == "delimiter=&list-type=2&prefix=a%20b%2Fc")
    }

    @Test func pathsKeepTheirSlashesButEscapeTheRest() {
        #expect(SigV4Signer.canonicalPath(of: URL(string: "https://h/bucket/Originals/2026/R 1.DNG")!) == "/bucket/Originals/2026/R%201.DNG")
        #expect(SigV4Signer.canonicalPath(of: URL(string: "https://h")!) == "/")
    }

    @Test func hashesPayloads() {
        #expect(SigV4Signer.sha256Hex(Data()) == emptyHash)
        #expect(SigV4Signer.sha256Hex(Data("Welcome to Amazon S3.".utf8)) == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
    }
}
