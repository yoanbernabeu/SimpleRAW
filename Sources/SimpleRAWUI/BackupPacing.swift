import Foundation

/// When a backup nobody asked for by hand may start.
///
/// Every trip back to the grid, every import and the launch ask for one, and a run is not
/// free: it lists the whole store and snapshots the catalog. So they are spaced out, and the
/// launch is left to the first thumbnails. "Back Up Now" is never paced.
public struct BackupPacing: Equatable, Sendable {
    /// How long after the launch the first automatic run may start.
    public var launchDelay: TimeInterval
    /// The quiet time between the end of a run and the start of the next automatic one.
    public var minimumInterval: TimeInterval

    public init(launchDelay: TimeInterval = 20, minimumInterval: TimeInterval = 5 * 60) {
        self.launchDelay = launchDelay
        self.minimumInterval = minimumInterval
    }

    /// How long a run asked for now has to wait; zero when it may start at once.
    public func delay(now: Date, launchedAt: Date, lastRunEndedAt: Date?) -> TimeInterval {
        let afterLaunch = launchedAt.addingTimeInterval(launchDelay)
        let afterLastRun = lastRunEndedAt?.addingTimeInterval(minimumInterval) ?? afterLaunch
        return max(0, max(afterLaunch, afterLastRun).timeIntervalSince(now))
    }
}
