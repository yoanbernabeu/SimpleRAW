import Foundation

/// The one seam between this and the sandbox, so that every rule around a bookmark can be
/// tried in a test. A bookmark is data only a sandboxed app can mint, and a test target is
/// not one.
public struct SecurityScope: Sendable {
    var makeBookmark: @Sendable (URL) throws -> Data
    var resolve: @Sendable (Data) throws -> (url: URL, isStale: Bool)
    var startAccess: @Sendable (URL) -> Bool
    var stopAccess: @Sendable (URL) -> Void

    public static let real = SecurityScope(
        makeBookmark: { try $0.bookmarkData(options: .withSecurityScope) },
        resolve: { data in
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            return (url, isStale)
        },
        startAccess: { $0.startAccessingSecurityScopedResource() },
        stopAccess: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Where the photographer's library is, kept in a way that still means something in a sandbox.
///
/// A path is no longer enough there: it carries no right to open anything, and a sandboxed app
/// may only reach what the person picked in a panel. What is kept instead is a bookmark, minted
/// when they pick the folder and resolved at every launch, which brings the right back with it.
///
/// Three things have to be right, and none of them can be tried by hand without a signed app,
/// which is why they are all in `LibraryLocationTests`. A bookmark goes **stale** when the
/// folder moves, and has to be written back fresh or it goes stale again for ever. One that no
/// longer resolves — a disk unplugged — has to be **given up**, so the app comes up and asks
/// rather than pointing at nothing. And the right taken for one folder has to be **given back**
/// when another is chosen: an app is allowed only so many at once.
///
/// Outside a sandbox there is nothing to mint, and the folder is remembered by path, so that a
/// development build behaves like the shipped one.
@MainActor
public final class LibraryLocation {
    public static let key = "libraryBookmark"
    /// What earlier versions wrote, and what a build with no sandbox still writes.
    static let pathKey = "libraryLocation"

    private let defaults: UserDefaults
    private let scope: SecurityScope
    /// The folder the right is currently held for, so that it can be given back.
    private var held: URL?

    public private(set) var url: URL?

    public init(defaults: UserDefaults = .standard, scope: SecurityScope = .real) {
        self.defaults = defaults
        self.scope = scope
        url = resolved()
    }

    /// Keeps the folder a person has just picked, and takes the right to it.
    public func remember(_ url: URL) {
        release()
        if let bookmark = try? scope.makeBookmark(url) {
            defaults.set(bookmark, forKey: Self.key)
            defaults.removeObject(forKey: Self.pathKey)
        } else {
            // No sandbox: nothing to mint, and the path is the whole of the right.
            defaults.removeObject(forKey: Self.key)
            defaults.set(url.path, forKey: Self.pathKey)
        }
        take(url)
    }

    /// Gives back the right, at quit or before another folder is chosen.
    public func release() {
        if let held { scope.stopAccess(held) }
        held = nil
        url = nil
    }

    private func resolved() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.key) else {
            return defaults.string(forKey: Self.pathKey).map { URL(fileURLWithPath: $0) }
        }
        guard let answer = try? scope.resolve(bookmark) else {
            // It will not resolve again tomorrow either: asking once is kinder than failing
            // at every launch.
            defaults.removeObject(forKey: Self.key)
            return nil
        }
        take(answer.url)
        if answer.isStale, let fresh = try? scope.makeBookmark(answer.url) {
            defaults.set(fresh, forKey: Self.key)
        }
        return answer.url
    }

    private func take(_ url: URL) {
        _ = scope.startAccess(url)
        held = url
        self.url = url
    }
}
