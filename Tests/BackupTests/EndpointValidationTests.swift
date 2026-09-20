import Foundation
import Testing
@testable import Backup

/// What the user types in the endpoint field is checked before it is saved or used.
@Suite struct EndpointValidationTests {
    @Test(arguments: ["https://s3.eu-west-3.amazonaws.com", "https://s3.fr-par.scw.cloud", "https://minio.example.com:9000"])
    func anHTTPSEndpointIsFine(text: String) throws {
        let result = try S3Endpoint.validate(text)
        #expect(result.url.absoluteString == text && !result.isInsecure)
    }

    /// Keys in a URL would end up in clear text in the settings file.
    @Test func credentialsInTheURLAreRefused() {
        #expect(throws: S3Endpoint.Problem.containsCredentials) { try S3Endpoint.validate("https://key:secret@s3.example.com") }
        #expect(throws: S3Endpoint.Problem.containsCredentials) { try S3Endpoint.validate("https://key@s3.example.com") }
    }

    @Test(arguments: ["", "   ", "s3.example.com", "ftp://s3.example.com", "https://", "file:///etc/passwd", "https://s3.example.com/?x=1", "https://s3.example.com/#a"])
    func whatIsNotAPlainWebAddressIsRefused(text: String) {
        #expect(throws: S3Endpoint.Problem.self) { try S3Endpoint.validate(text) }
    }

    /// Plain http sends the photos in clear text. It is allowed, because a NAS or a test
    /// server on the local network has nothing else, but it is never silent.
    @Test func httpIsAllowedButFlagged() throws {
        #expect(try S3Endpoint.validate("http://192.168.1.20:9000").isInsecure)
        #expect(try S3Endpoint.validate("http://minio.example.com").isInsecure)
    }

    @Test func surroundingSpacesAndATrailingSlashAreForgiven() throws {
        #expect(try S3Endpoint.validate("  https://s3.example.com/  ").url.absoluteString == "https://s3.example.com")
    }

    @Test func everyProblemExplainsItself() {
        for problem in [S3Endpoint.Problem.empty, .notAWebAddress, .containsCredentials, .hasQueryOrFragment] {
            #expect(problem.errorDescription?.isEmpty == false)
        }
    }
}
