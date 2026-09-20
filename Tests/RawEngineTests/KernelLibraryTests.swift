import Foundation
import Testing
@testable import RawEngine

/// Where the compiled kernels are looked for, and — the point of the whole type — what
/// happens when they are nowhere.
///
/// The installed app died here: `Bundle.module`, the accessor SwiftPM writes, ends in
/// `fatalError` when the resource bundle is not among the three places it knows. Opening a
/// photograph asks the inspector which sliders to offer, the inspector asks whether this
/// build can warp a picture, and a packaging accident became a crash on the main thread.
/// A missing library is a missing slider, never a dead app: that is what these hold to.
@Suite struct KernelLibraryTests {
    private let files = FileManager.default

    /// A folder holding a resource bundle laid out the given way, or no bundle at all.
    private func folder(_ layout: Layout) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "KernelLibraryTests-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = root.appending(path: KernelLibrary.bundleName + ".bundle")
        switch layout {
        case .none:
            break
        case .empty:
            try files.createDirectory(at: bundle, withIntermediateDirectories: true)
        case .flat:
            try files.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: bundle.appending(path: KernelLibrary.resourceName))
        case .macOS:
            let resources = bundle.appending(path: "Contents/Resources")
            try files.createDirectory(at: resources, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: resources.appending(path: KernelLibrary.resourceName))
        }
        return root
    }

    private enum Layout { case none, empty, flat, macOS }

    /// What `swift build` writes on this machine: a bundle with a `Contents/Resources`.
    @Test func itReadsTheLayoutABuildWritesHere() throws {
        let folder = try folder(.macOS)
        let url = try #require(KernelLibrary.url(searching: [folder]))
        #expect(url.lastPathComponent == KernelLibrary.resourceName)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    /// And what the release runner wrote in the copy that crashed: the library at the root of
    /// the bundle, no `Contents`, no `Info.plist`. Two toolchains, two layouts, one engine.
    @Test func itReadsTheFlatLayoutAReleaseCanShip() throws {
        let folder = try folder(.flat)
        let url = try #require(KernelLibrary.url(searching: [folder]))
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    /// The one that killed the app. Nothing found is an answer, not a reason to stop.
    @Test func itAnswersNothingWhenNoBundleWasInstalled() throws {
        #expect(KernelLibrary.url(searching: [try folder(.none)]) == nil)
    }

    /// A bundle that arrived without its library — an interrupted copy, a build with no Metal
    /// compiler behind it — is the same case.
    @Test func itAnswersNothingWhenTheBundleHoldsNoLibrary() throws {
        #expect(KernelLibrary.url(searching: [try folder(.empty)]) == nil)
    }

    /// Nowhere to look is the case of a host that has no bundle and no executable folder to
    /// speak of. It is still not a crash.
    @Test func itAnswersNothingWhenThereIsNowhereToLook() {
        #expect(KernelLibrary.url(searching: []) == nil)
    }

    /// Several folders are searched in order, so that the one belonging to this code is read
    /// before whatever else happens to sit next to the executable.
    @Test func itTakesTheFirstFolderThatHasOne() throws {
        let empty = try folder(.none)
        let real = try folder(.macOS)
        #expect(KernelLibrary.url(searching: [empty, real]) == real.appending(
            path: "\(KernelLibrary.bundleName).bundle/Contents/Resources/\(KernelLibrary.resourceName)"
        ))
    }

    /// The engine looks beside its own code and beside the executable: a test bundle, a bare
    /// command-line tool and an app wrapper all put the resources in one of those.
    @Test func itLooksBesideItsOwnCodeAndBesideTheExecutable() {
        let folders = KernelLibrary.searchedFolders
        #expect(!folders.isEmpty)
        #expect(Set(folders).count == folders.count, "the same folder is searched twice")
    }

    /// And in this build, it finds what the build produced: `isAvailable` is the answer of
    /// the search, with no `Bundle.module` anywhere behind it.
    @Test func itFindsTheLibraryOfThisBuild() throws {
        let found = KernelLibrary.url(searching: KernelLibrary.searchedFolders)
        let holdsKernels = try found.map { try !Data(contentsOf: $0).isEmpty } ?? false
        #expect(holdsKernels == MetalKernels.isAvailable)
    }

    /// The accessor that ends in `fatalError` is not to come back in by another door: an
    /// engine that cannot find a resource must go on without it.
    @Test func noSourceFileReachesForBundleModule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RawEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the repository
            .appending(path: "Sources")
        let swiftFiles = try #require(files.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in swiftFiles where file.pathExtension == "swift" {
            // Comments are where the story of this rule is told: it is the code that is read.
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(
                !code.contains { $0.contains("Bundle.module") },
                "\(file.lastPathComponent) reaches for Bundle.module"
            )
        }
    }
}
