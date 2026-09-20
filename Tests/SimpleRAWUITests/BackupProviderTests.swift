import Backup
import Foundation
import Testing
@testable import SimpleRAWUI

@Suite struct BackupProviderTests {
    @Test func theListEndsWithTheWayOutAndNamesEveryProviderOnce() {
        #expect(BackupProvider.allCases.last == .other)
        #expect(Set(BackupProvider.allCases.map(\.name)).count == BackupProvider.allCases.count)
    }

    @Test(arguments: [
        (BackupProvider.amazonS3, "eu-west-3", "", "https://s3.eu-west-3.amazonaws.com"),
        (.scaleway, "fr-par", "", "https://s3.fr-par.scw.cloud"),
        (.backblazeB2, "eu-central-003", "", "https://s3.eu-central-003.backblazeb2.com"),
        (.cloudflareR2, "auto", "0123abcd", "https://0123abcd.r2.cloudflarestorage.com"),
        (.ovhcloud, "gra", "", "https://s3.gra.io.cloud.ovh.net"),
        (.wasabi, "eu-central-1", "", "https://s3.eu-central-1.wasabisys.com"),
    ])
    func aProviderKnowsItsAddress(provider: BackupProvider, region: String, account: String, expected: String) {
        #expect(provider.endpoint(region: region, account: account) == expected)
    }

    /// What the table builds goes through the same check as what a user types.
    @Test(arguments: BackupProvider.allCases.filter { $0 != .other })
    func everyProposedRegionGivesAnEncryptedAddressAndFindsItsProviderAgain(provider: BackupProvider) throws {
        #expect(provider.regions.contains(provider.defaultRegion))
        for region in provider.regions {
            let text = try #require(provider.endpoint(region: region, account: "0123abcd"))
            let validated = try S3Endpoint.validate(text)
            #expect(!validated.isInsecure)
            let match = BackupProvider.matching(endpoint: validated.url)
            #expect(match.provider == provider)
            #expect(match.account == (provider.needsAccount ? "0123abcd" : ""))
        }
    }

    @Test func anAddressNobodyKnowsIsTheOtherProvider() throws {
        for text in ["http://127.0.0.1:9000", "https://nas.local", "https://s3.amazonaws.com.evil.example", "https://s3..amazonaws.com"] {
            #expect(BackupProvider.matching(endpoint: try #require(URL(string: text))).provider == .other)
        }
        #expect(BackupProvider.other.endpoint(region: "us-east-1", account: "") == nil)
    }

    /// A region the table does not propose (set up by hand, or opened since) stays usable.
    @Test func aRegionTheTableDoesNotKnowIsKept() throws {
        let url = try #require(URL(string: "https://s3.me-south-1.amazonaws.com"))
        #expect(BackupProvider.matching(endpoint: url).provider == .amazonS3)
        #expect(BackupProvider.amazonS3.regions(including: "me-south-1").first == "me-south-1")
        #expect(BackupProvider.amazonS3.regions(including: "eu-west-3") == BackupProvider.amazonS3.regions)
    }

    /// The account and the region end up in a host name: nothing else may be put there.
    @Test(arguments: ["evil.example/", "a@b", "a b", "", "x.y"])
    func whatGoesInTheAddressIsOnlyLettersDigitsAndDashes(text: String) {
        #expect(BackupProvider.cloudflareR2.endpoint(region: "auto", account: text) == nil)
        #expect(BackupProvider.amazonS3.endpoint(region: text, account: "") == nil)
    }
}

@Suite struct BackupFormTests {
    private let saved = S3Configuration(endpoint: URL(string: "https://s3.fr-par.scw.cloud")!, region: "fr-par", bucket: "photos", prefix: "simpleraw")

    @Test func aNewFormProposesAProviderAndOnlyNeedsANameAndKeys() throws {
        var form = BackupForm(saved: nil)
        #expect(form.provider != .other && form.folder == "simpleraw")
        #expect(form.configuration == .failure(.missingStorageName))
        #expect(!form.canSubmit(saved: nil))

        form.storageName = "  photos "
        let configuration = try form.configuration.get()
        #expect(configuration.bucket == "photos" && configuration.region == form.provider.defaultRegion)
        #expect(configuration.endpoint.absoluteString == form.provider.endpoint(region: form.region, account: ""))
        #expect(form.keys(saved: nil) == .needed && !form.canSubmit(saved: nil))

        form.accessKey = "AKIA"
        #expect(form.keys(saved: nil) == .incomplete && !form.canSubmit(saved: nil))
        form.secretKey = "secret"
        #expect(form.keys(saved: nil) == .complete && form.canSubmit(saved: nil))
    }

    @Test func aSavedConfigurationComesBackAsItWasEntered() throws {
        let form = BackupForm(saved: saved)
        #expect(form.provider == .scaleway && form.region == "fr-par" && form.storageName == "photos" && form.folder == "simpleraw")
        #expect(form.accessKey.isEmpty && form.secretKey.isEmpty)
        #expect(try form.configuration.get() == saved)
        #expect(form.keys(saved: saved) == .keepsStored && form.canSubmit(saved: saved))

        let r2 = S3Configuration(endpoint: URL(string: "https://0123abcd.r2.cloudflarestorage.com")!, region: "auto", bucket: "photos")
        #expect(BackupForm(saved: r2).provider == .cloudflareR2 && BackupForm(saved: r2).account == "0123abcd")
        #expect(try BackupForm(saved: r2).configuration.get() == r2)

        let own = S3Configuration(endpoint: URL(string: "http://127.0.0.1:9000")!, region: "us-east-1", bucket: "photos")
        #expect(BackupForm(saved: own).provider == .other && BackupForm(saved: own).endpoint == "http://127.0.0.1:9000")
        #expect(try BackupForm(saved: own).configuration.get() == own)
        #expect(BackupForm(saved: own).isInsecure && !form.isInsecure)
    }

    /// Stored keys belong to their destination: the form asks for them before the session refuses.
    @Test func changingTheDestinationAsksForTheKeysAgain() {
        var form = BackupForm(saved: saved)
        form.folder = "elsewhere"
        #expect(form.keys(saved: saved) == .keepsStored)
        form.region = "nl-ams"
        #expect(form.keys(saved: saved) == .neededAgain && !form.canSubmit(saved: saved))
        form.accessKey = "AKIA"
        form.secretKey = "secret"
        #expect(form.keys(saved: saved) == .complete && form.canSubmit(saved: saved))
    }

    @Test func choosingAnotherProviderMovesToOneOfItsRegions() {
        var form = BackupForm(saved: saved)
        form.provider = .wasabi
        #expect(form.region == BackupProvider.wasabi.defaultRegion)
        form.region = "eu-west-1"
        form.provider = .amazonS3
        #expect(form.region == "eu-west-1")
        form.provider = .cloudflareR2
        #expect(form.region == "auto" && form.configuration == .failure(.missingAccount))
    }

    /// The window points at a mistake, not at a field nobody has filled in yet.
    @Test func onlyWhatWasTypedWrongIsPointedAt() {
        var form = BackupForm(saved: nil)
        #expect(form.visibleProblem == nil)
        form.storageName = "My Photos"
        #expect(form.visibleProblem == .naming(.invalidBucket))
        form.storageName = "photos"
        form.folder = "../up"
        #expect(form.visibleProblem == .naming(.invalidPrefix))
        form.folder = ""
        form.provider = .other
        #expect(form.visibleProblem == nil)
        form.endpoint = "nas"
        #expect(form.visibleProblem == .endpoint(.notAWebAddress))
    }

    @Test func aProblemIsSaidInPlainWords() {
        var form = BackupForm(saved: nil)
        form.storageName = "photos"
        form.provider = .other
        // Nothing typed yet is not a mistake to point at.
        #expect(form.configuration == .failure(.endpoint(.empty)) && form.endpointProblem == nil)
        form.endpoint = "ftp://nas.local"
        #expect(form.configuration == .failure(.endpoint(.notAWebAddress)) && form.endpointProblem == .endpoint(.notAWebAddress))
        form.provider = .cloudflareR2
        #expect(form.endpointProblem == nil)
        form.account = "not an account"
        #expect(form.endpointProblem == .missingAccount)
        // The names go through the rules of the backup module, like the address.
        form.provider = .other
        form.endpoint = "https://nas.local"
        form.storageName = "My Photos"
        #expect(form.configuration == .failure(.naming(.invalidBucket)))
        form.storageName = "photos"
        form.folder = "../elsewhere"
        #expect(form.configuration == .failure(.naming(.invalidPrefix)))
        form.folder = "/backups/simpleraw/"
        #expect((try? form.configuration.get())?.prefix == "backups/simpleraw")
        for problem in [BackupForm.Problem.missingStorageName, .missingAccount, .endpoint(.notAWebAddress), .naming(.invalidBucket)] {
            #expect(problem.errorDescription?.isEmpty == false)
        }
    }
}
