import Foundation
import Testing
@testable import SimpleRAWUI

/// Where the library is, once the app lives in a sandbox: a path is no longer enough, because
/// a path carries no right to open anything. What is kept is a bookmark, and the rules about
/// renewing and giving up on one are what this covers — none of it can be tried by hand
/// without shipping a signed app first.
@MainActor
@Suite struct LibraryLocationTests {
    private let folder = URL(fileURLWithPath: "/tmp/a-library")
    private let other = URL(fileURLWithPath: "/tmp/another-library")

    private func defaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "simpleraw-tests-\(UUID().uuidString)")!
        return defaults
    }

    /// A stand-in for the system: bookmarks are data the sandbox mints, and a test cannot ask
    /// for one without being a sandboxed app. What it can do is check every decision made
    /// around them.
    private final class FakeScope: @unchecked Sendable {
        var minted: [Data: URL] = [:]
        var stale: Set<Data> = []
        var refuses = false
        private(set) var started: [URL] = []
        private(set) var stopped: [URL] = []
        private var next = 0

        var scope: SecurityScope {
            SecurityScope(
                makeBookmark: { url in
                    if self.refuses { throw CocoaError(.fileNoSuchFile) }
                    self.next += 1
                    let data = Data("bookmark-\(self.next)".utf8)
                    self.minted[data] = url
                    return data
                },
                resolve: { data in
                    guard let url = self.minted[data] else { throw CocoaError(.fileReadCorruptFile) }
                    return (url, self.stale.contains(data))
                },
                startAccess: { self.started.append($0); return true },
                stopAccess: { self.stopped.append($0) }
            )
        }
    }

    @Test func nothingIsRememberedAtFirst() {
        let location = LibraryLocation(defaults: defaults(), scope: FakeScope().scope)
        #expect(location.url == nil)
    }

    @Test func aChosenFolderComesBackOnTheNextLaunch() throws {
        let fake = FakeScope()
        let defaults = defaults()
        let first = LibraryLocation(defaults: defaults, scope: fake.scope)
        first.remember(folder)
        first.release()  // quitting

        let next = LibraryLocation(defaults: defaults, scope: fake.scope)
        #expect(next.url == folder)
        // Opening the library reads and writes inside it, so the right is taken when the
        // folder is chosen and again every time it is found: once per launch, never leaked.
        #expect(fake.started == [folder, folder])
        #expect(fake.stopped == [folder])
    }

    /// A bookmark goes stale when the folder is moved or the system changes under it. It still
    /// resolves, and the fresh one has to be written back — otherwise it goes stale again on
    /// every launch until the day it stops resolving at all.
    @Test func aStaleBookmarkIsRenewedRatherThanLost() throws {
        let fake = FakeScope()
        let defaults = defaults()
        LibraryLocation(defaults: defaults, scope: fake.scope).remember(folder)
        let first = try #require(defaults.data(forKey: LibraryLocation.key))
        fake.stale.insert(first)

        let next = LibraryLocation(defaults: defaults, scope: fake.scope)
        #expect(next.url == folder)
        #expect(defaults.data(forKey: LibraryLocation.key) != first)
    }

    /// A folder that was on a disk now unplugged: the app must come up and ask, not fall over
    /// or keep pointing at something it cannot open.
    @Test func aBookmarkThatNoLongerResolvesIsForgotten() {
        let fake = FakeScope()
        let defaults = defaults()
        defaults.set(Data("nonsense".utf8), forKey: LibraryLocation.key)

        let location = LibraryLocation(defaults: defaults, scope: fake.scope)
        #expect(location.url == nil)
        #expect(defaults.data(forKey: LibraryLocation.key) == nil)
    }

    /// Choosing another library gives back the right to the first: a sandboxed app is allowed
    /// only so many of these at once, and one leaked per change adds up over a lifetime.
    @Test func changingLibraryGivesBackTheRightToTheOldOne() {
        let fake = FakeScope()
        let location = LibraryLocation(defaults: defaults(), scope: fake.scope)
        location.remember(folder)
        location.remember(other)
        #expect(fake.stopped == [folder])
        #expect(location.url == other)
    }

    /// Outside a sandbox — every development build — there is no bookmark to mint. The folder
    /// is still remembered, by path, so that `make run` behaves like the shipped app.
    @Test func withoutASandboxTheFolderIsRememberedByPath() {
        let fake = FakeScope()
        fake.refuses = true
        let defaults = defaults()
        LibraryLocation(defaults: defaults, scope: fake.scope).remember(folder)
        #expect(LibraryLocation(defaults: defaults, scope: fake.scope).url == folder)
    }
}
