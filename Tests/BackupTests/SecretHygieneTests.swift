import Foundation
import Testing
@testable import Backup

/// Keys are never written to a file or a log. The day a log arrives, printing the wrong value
/// must still not print the secret.
@Suite struct SecretHygieneTests {
    let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    var credentials: S3Credentials { S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: secret) }

    private struct Holder {
        let credentials: S3Credentials
        let signer: SigV4Signer
    }

    @Test func credentialsDoNotPrintTheirSecret() {
        #expect(!"\(credentials)".contains(secret))
        #expect(!String(describing: credentials).contains(secret))
        #expect(!String(reflecting: credentials).contains(secret))
        #expect(!"\([credentials])".contains(secret))
        #expect(!"\(Optional(credentials) as Any)".contains(secret))
        // The access key is an identifier, and knowing which one is in use helps.
        #expect("\(credentials)".contains("AKIAIOSFODNN7EXAMPLE"))
    }

    @Test func reflectionDoesNotReachTheSecret() {
        var dumped = ""
        dump(credentials, to: &dumped)
        #expect(!dumped.contains(secret))
        #expect(!Mirror(reflecting: credentials).children.contains { "\($0.value)".contains(secret) })
    }

    @Test func whatHoldsCredentialsDoesNotPrintThemEither() {
        let holder = Holder(credentials: credentials, signer: SigV4Signer(credentials: credentials, region: "us-east-1"))
        var dumped = ""
        dump(holder, to: &dumped)
        #expect(!dumped.contains(secret))
        #expect(!"\(holder)".contains(secret))
        #expect(!String(reflecting: holder).contains(secret))
    }

    @Test func maskingChangesNothingToWhatIsSigned() {
        #expect(credentials.secretKey == secret)
        #expect(credentials == S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: secret))
        #expect(credentials != S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "another"))
    }
}

/// An error from the server is shown to the user: it says what went wrong, briefly, and
/// nothing about the request that was signed.
@Suite struct S3ErrorMessageTests {
    /// What S3 answers to a bad signature: the key, and the very strings that were signed.
    @Test func theSignedRequestEchoedByTheServerIsNeverRepeated() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>SignatureDoesNotMatch</Code>
        <Message>The request signature we calculated does not match the signature you provided.</Message>
        <AWSAccessKeyId>AKIAIOSFODNN7EXAMPLE</AWSAccessKeyId>
        <StringToSign>AWS4-HMAC-SHA256\n20130524T000000Z\n20130524/us-east-1/s3/aws4_request\n7344ae5b</StringToSign>
        <SignatureProvided>f0e8bdb87c964420e857bd35b5d6ed31</SignatureProvided>
        <StringToSignBytes>41 57 53 34</StringToSignBytes>
        <CanonicalRequest>PUT\n/photos/Originals/secret-place.DNG\n\nhost:s3.example.com</CanonicalRequest>
        <CanonicalRequestBytes>50 55 54</CanonicalRequestBytes>
        <RequestId>4442587FB7D0A2F9</RequestId></Error>
        """
        let error = S3Error(status: 403, body: Data(xml.utf8))
        #expect(error.code == "SignatureDoesNotMatch")
        for text in [error.localizedDescription, "\(error)", String(reflecting: error)] {
            for leaked in ["AKIAIOSFODNN7EXAMPLE", "AWS4-HMAC-SHA256", "aws4_request", "f0e8bdb87c964420", "secret-place", "41 57 53 34", "50 55 54"] {
                #expect(!text.contains(leaked))
            }
        }
        #expect(error.localizedDescription.contains("does not match"))
    }

    @Test func aLongMessageIsCutShort() {
        let xml = "<Error><Code>\(String(repeating: "C", count: 500))</Code><Message>\(String(repeating: "word ", count: 600))</Message></Error>"
        let error = S3Error(status: 500, body: Data(xml.utf8))
        #expect((error.message?.count ?? 0) <= 201 && error.message?.hasSuffix("…") == true)
        #expect((error.code?.count ?? 0) <= 65)
        #expect(error.localizedDescription.count < 320)
    }

    @Test func controlCharactersAreTakenOut() {
        let xml = "<Error><Code>Access\u{7F}Denied</Code><Message>line one\nline two\ttab &#x202E;reversed\u{7F}</Message></Error>"
        let error = S3Error(status: 403, body: Data(xml.utf8))
        #expect(error.message == "line one line two tab reversed")
        #expect(error.code == "Access Denied")
    }
}
