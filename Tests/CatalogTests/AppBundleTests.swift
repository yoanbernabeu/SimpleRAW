import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Catalog

/// The app's wrapper, checked here rather than read off a shell script: what a bundle claims
/// it can open is a promise the Finder makes on the app's behalf, and the only way to keep it
/// honest is to build it from the list the importer actually uses.
@Suite struct AppBundleTests {
    private func plist() throws -> [String: Any] {
        let data = try #require(AppBundle.infoPlist.data(using: .utf8))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theInfoPlistIsAPropertyList() throws {
        let plist = try plist()
        #expect(plist["CFBundleExecutable"] as? String == AppBundle.executable)
        #expect(plist["CFBundleIdentifier"] as? String == AppBundle.identifier)
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
    }

    /// The Finder offers the app for a file because of this list. A type the engine opens and
    /// the bundle does not declare is a photo nobody can double-click; the other way round is
    /// an app that takes a file and then says it cannot read it.
    @Test func itOffersToOpenExactlyWhatTheAppCanRead() throws {
        let documents = try #require(try plist()["CFBundleDocumentTypes"] as? [[String: Any]])
        let declared = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        #expect(declared == Set(Importer.importedTypes.map(\.identifier)))
    }

    /// Nothing here uses encryption beyond what the system offers, and saying so once is what
    /// spares every upload a compliance question.
    @Test func itDeclaresNoEncryptionOfItsOwn() throws {
        #expect(try plist()["ITSAppUsesNonExemptEncryption"] as? Bool == false)
    }

    /// The sandbox, and nothing that opens a hole in it. Each of these was asked for by
    /// something the app does; a new one has to be argued for here first.
    @Test func theEntitlementsAreTheSandboxAndThreeThingsItNeeds() throws {
        let data = try #require(AppBundle.entitlements.data(using: .utf8))
        let rights = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(rights["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(rights["com.apple.security.network.client"] as? Bool == true)
        #expect(rights["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(rights.count == 3)
    }

    /// The escapes a hardened runtime allows, every one of which gives back what the runtime
    /// was for. None of them is here, and a test says so rather than a comment.
    @Test func itAsksForNoWayOutOfTheHardenedRuntime() throws {
        for escape in [
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.disable-executable-page-protection",
        ] {
            #expect(!AppBundle.entitlements.contains(escape), "\(escape) is in the entitlements")
        }
    }
}
