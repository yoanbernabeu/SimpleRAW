import Foundation

/// RAW files used by end-to-end tests. `Samples/` is git-ignored: suites relying on it are
/// skipped when it is empty. `SIMPLERAW_NO_SAMPLES=1` hides them, to run the suite as a fresh
/// clone would (`make test-clone`).
public enum Sample {
    public static let all: [URL] = {
        guard ProcessInfo.processInfo.environment["SIMPLERAW_NO_SAMPLES"] == nil else { return [] }
        return files(in: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Samples"))
    }()

    /// Any sample, for a test that only needs a real RAW file.
    public static var url: URL? { all.first }

    /// The photograph the tests that assert particular values were written against: the CC0
    /// Ricoh GR III file named in `CLAUDE.md`.
    ///
    /// `all` is every DNG in the folder, and the folder is meant to be dropped into — that is
    /// how a file that misbehaves becomes a regression case. So `all.first` is whatever sorts
    /// first, which is not the same thing as *the* reference photograph at all. A test that
    /// says "6000 × 4000" or "a GR III" must ask for this one, and skip when it is not there.
    public static var reference: URL? { all.first { $0.lastPathComponent == referenceName } }

    public static let referenceName = "R0000357.DNG"

    /// The DNG files of a folder, sorted by name. A git worktree links to the samples of the
    /// main checkout, and listing a link fails unless it is resolved first: every suite
    /// relying on samples was then skipped without a word, `make bench` included.
    public static func files(in folder: URL) -> [URL] {
        let resolved = folder.resolvingSymlinksInPath()
        let files = (try? FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
