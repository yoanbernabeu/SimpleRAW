import Foundation
import Testing
@testable import Backup

/// Bucket, prefix and region end up in URLs and in keys: they are checked where they come
/// in, typed by the user or read from the settings file.
@Suite struct ConfigurationValidationTests {
    @Test(arguments: ["photos", "my-photos", "my.photos.2026", "abc", "0photos9", String(repeating: "a", count: 63)])
    func aBucketNamedTheWayS3NamesThemIsFine(name: String) throws {
        #expect(try S3Naming.bucket(name) == name)
        #expect(try S3Naming.bucket("  \(name) ") == name)
    }

    @Test(arguments: [
        "ab", String(repeating: "a", count: 64), "Photos", "my_photos", "-photos", "photos-", ".photos", "photos.",
        "my..photos", "photos/2026", "../photos", "..", "photos?x=1", "pho tos", "photos\u{0}", "phötos",
    ])
    func anyOtherBucketNameIsRefused(name: String) {
        #expect(throws: S3Naming.Problem.invalidBucket) { try S3Naming.bucket(name) }
    }

    @Test func anEmptyBucketHasAMessageOfItsOwn() {
        #expect(throws: S3Naming.Problem.emptyBucket) { try S3Naming.bucket("   ") }
    }

    @Test(arguments: [
        ("", ""), ("  ", ""), ("/", ""), ("simpleraw", "simpleraw"), ("/simpleraw/", "simpleraw"),
        ("backups//simpleraw", "backups/simpleraw"), (" backups/my mac/ ", "backups/my mac"), ("été/2026", "été/2026"),
    ])
    func aPrefixIsBroughtToOneSpelling(typed: String, expected: String) throws {
        #expect(try S3Naming.prefix(typed) == expected)
    }

    @Test(arguments: ["..", ".", "../other", "simpleraw/../other", "simpleraw/./x", "a/..", "a\u{0}b", "a\nb", String(repeating: "a", count: 513)])
    func aPrefixThatGoesSomewhereElseIsRefused(typed: String) {
        #expect(throws: S3Naming.Problem.invalidPrefix) { try S3Naming.prefix(typed) }
    }

    @Test func aRegionIsAPlainWordAndDefaultsToTheOneOfS3() throws {
        #expect(try S3Naming.region(" eu-west-3 ") == "eu-west-3")
        #expect(try S3Naming.region("fr-par") == "fr-par")
        #expect(try S3Naming.region("") == "us-east-1")
        for region in ["eu/west", "eu west", "eu-west-3\n", "../x", String(repeating: "a", count: 65)] {
            #expect(throws: S3Naming.Problem.invalidRegion) { try S3Naming.region(region) }
        }
    }

    @Test func aConfigurationIsValidatedAsAWhole() throws {
        let configuration = try S3Configuration.validated(endpoint: " https://s3.example.com/ ", region: "", bucket: " photos ", prefix: "/simpleraw/")
        #expect(configuration == S3Configuration(endpoint: URL(string: "https://s3.example.com")!, region: "us-east-1", bucket: "photos", prefix: "simpleraw"))
        #expect(throws: S3Endpoint.Problem.self) { try S3Configuration.validated(endpoint: "ftp://x", region: "", bucket: "photos", prefix: "") }
        #expect(throws: S3Naming.Problem.invalidBucket) { try S3Configuration.validated(endpoint: "https://s3.example.com", region: "", bucket: "../x", prefix: "") }
    }

    /// What the settings file says is not trusted more than what the user types: it may have
    /// been written by an older version, or by something else.
    @Test func aDecodedConfigurationCanBeCheckedAgain() throws {
        let fine = S3Configuration(endpoint: URL(string: "https://s3.example.com")!, region: "eu-west-3", bucket: "photos", prefix: "simpleraw")
        #expect(try fine.validated() == fine)

        var hostile = fine
        hostile.bucket = "photos/../other"
        #expect(throws: S3Naming.Problem.invalidBucket) { try hostile.validated() }
        hostile = fine
        hostile.prefix = "../other"
        #expect(throws: S3Naming.Problem.invalidPrefix) { try hostile.validated() }
        hostile = fine
        hostile.endpoint = URL(string: "https://key:secret@s3.example.com")!
        #expect(throws: S3Endpoint.Problem.containsCredentials) { try hostile.validated() }
        hostile.endpoint = URL(string: "file:///etc")!
        #expect(throws: S3Endpoint.Problem.self) { try hostile.validated() }
    }

    @Test func everyProblemExplainsItself() {
        for problem in [S3Naming.Problem.emptyBucket, .invalidBucket, .invalidPrefix, .invalidRegion] {
            #expect(problem.errorDescription?.isEmpty == false)
        }
    }
}
