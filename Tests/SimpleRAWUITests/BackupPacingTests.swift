import Backup
import Foundation
import Testing
@testable import SimpleRAWUI

@Suite struct BackupPacingTests {
    let pacing = BackupPacing(launchDelay: 20, minimumInterval: 300)
    let launch = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func theFirstRunWaitsForTheLaunchToBeOver() {
        #expect(pacing.delay(now: launch, launchedAt: launch, lastRunEndedAt: nil) == 20)
        #expect(pacing.delay(now: launch + 5, launchedAt: launch, lastRunEndedAt: nil) == 15)
        #expect(pacing.delay(now: launch + 60, launchedAt: launch, lastRunEndedAt: nil) == 0)
    }

    @Test func runsAreSpacedOut() {
        let ended = launch + 100
        #expect(pacing.delay(now: ended, launchedAt: launch, lastRunEndedAt: ended) == 300)
        #expect(pacing.delay(now: ended + 290, launchedAt: launch, lastRunEndedAt: ended) == 10)
        #expect(pacing.delay(now: ended + 301, launchedAt: launch, lastRunEndedAt: ended) == 0)
    }

    /// A run made by hand during the launch does not shorten the wait of the automatic one.
    @Test func theLongerWaitWins() {
        #expect(pacing.delay(now: launch + 2, launchedAt: launch, lastRunEndedAt: launch + 1) == 299)
        let calm = BackupPacing(launchDelay: 20, minimumInterval: 5)
        #expect(calm.delay(now: launch + 2, launchedAt: launch, lastRunEndedAt: launch + 1) == 18)
    }
}

/// A clock the test owns: sleeping records the wait and moves the time, without waiting.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSinceReferenceDate: 0)
    private var recorded: [TimeInterval] = []
    /// When set, sleepers wait here until it opens.
    let holdsSleepers: BackupGate?

    init(holdsSleepers: Bool = false) {
        self.holdsSleepers = holdsSleepers ? BackupGate() : nil
    }

    var now: Date { lock.withLock { time } }
    var sleeps: [TimeInterval] { lock.withLock { recorded } }
    func advance(by seconds: TimeInterval) { lock.withLock { time += seconds } }

    func sleep(_ seconds: TimeInterval) async {
        lock.withLock { recorded.append(seconds) }
        await holdsSleepers?.wait()
        advance(by: seconds)
    }
}

actor BackupGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A store that counts the runs it sees, and can hold what it is asked in the middle.
final class ObservedStore: ObjectStore, @unchecked Sendable {
    let inner = InMemoryObjectStore()
    private let lock = NSLock()
    private var counts = (runs: 0, listings: 0)
    /// Opens when a run has started.
    let entered = BackupGate()
    let holdsRuns: BackupGate?
    /// Opens when a file other than the catalog's hash is being downloaded.
    let downloading = BackupGate()
    let holdsDownloads: BackupGate?
    let holdsListings: BackupGate?

    init(holdsRuns: Bool = false, holdsDownloads: Bool = false, holdsListings: Bool = false) {
        self.holdsRuns = holdsRuns ? BackupGate() : nil
        self.holdsDownloads = holdsDownloads ? BackupGate() : nil
        self.holdsListings = holdsListings ? BackupGate() : nil
    }

    /// Every run reads the hash of the catalog last uploaded, once; it only lists the store
    /// when it does not remember what is in it.
    var runs: Int { lock.withLock { counts.runs } }
    var listings: Int { lock.withLock { counts.listings } }

    func list(prefix: String) async throws -> [S3Object] {
        lock.withLock { counts.listings += 1 }
        await holdsListings?.wait()
        return try await inner.list(prefix: prefix)
    }

    func get(_ key: String, to destination: URL) async throws {
        if key == "catalog.sqlite.sha256" {
            lock.withLock { counts.runs += 1 }
            await entered.open()
            await holdsRuns?.wait()
        } else {
            await downloading.open()
            await holdsDownloads?.wait()
        }
        try await inner.get(key, to: destination)
    }

    func head(_ key: String) async throws -> S3Object? { try await inner.head(key) }
    func put(_ key: String, file: URL) async throws { try await inner.put(key, file: file) }
    func put(_ key: String, data: Data) async throws { try await inner.put(key, data: data) }
}

/// Some of these tests hold a run in the middle: a bug must fail them, not hang the suite.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct BackupSchedulingTests {
    let sandbox: BackupSessionSandbox

    init() throws {
        sandbox = try BackupSessionSandbox()
    }

    private func configured(store: ObservedStore, clock: FakeClock) async -> BackupSession {
        let session = sandbox.session(store: store, clock: clock)
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        return session
    }

    /// The launch belongs to the first thumbnails: the backup asked for at launch waits.
    @Test func theLaunchBackupWaitsForTheAppToSettle() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(), FakeClock())
        let session = await configured(store: store, clock: clock)
        clock.advance(by: 5)
        session.backUpSoon()
        #expect(store.runs == 0)
        await session.pendingRun?.value
        #expect(clock.sleeps == [15] && store.runs == 1)
        guard case .upToDate = session.status else { Issue.record("expected a run, got \(session.status)"); return }
    }

    /// Every trip back to the grid asks for a backup; a run lists the whole store.
    @Test func automaticRunsAreSpacedOutAndAskingTwiceRunsOnce() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(), FakeClock())
        let session = await configured(store: store, clock: clock)
        session.backUpSoon()
        await session.pendingRun?.value

        edit(rating: 1)
        session.backUpSoon()
        session.backUpSoon()
        session.backUpSoon()
        await session.pendingRun?.value
        #expect(clock.sleeps == [20, 300] && store.runs == 2)

        clock.advance(by: 1000)
        edit(rating: 2)
        session.backUpSoon()
        await session.pendingRun?.value
        #expect(clock.sleeps == [20, 300] && store.runs == 3)
    }

    /// Going back to the grid without having changed anything costs nothing: not a snapshot
    /// of the catalog, not a request, not a trip to the Keychain. Back Up Now still runs.
    @Test func anAutomaticRunIsSkippedWhenTheCatalogHasNotMoved() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(), FakeClock())
        let session = await configured(store: store, clock: clock)
        session.backUpSoon()
        await session.pendingRun?.value
        let reads = sandbox.credentials.reads

        clock.advance(by: 1000)
        session.backUpSoon()
        await session.pendingRun?.value
        #expect(store.runs == 1 && sandbox.credentials.reads == reads)
        guard case .upToDate = session.status else { Issue.record("expected the status of the last run, got \(session.status)"); return }

        await session.runNow()
        #expect(store.runs == 2)

        edit(rating: 3)
        session.backUpSoon()
        await session.pendingRun?.value
        #expect(store.runs == 3)
    }

    /// A failed run sent nothing for sure: the next automatic one is not skipped.
    @Test func aFailedRunIsNotTakenForABackup() async {
        defer { sandbox.cleanUp() }
        let clock = FakeClock()
        let session = sandbox.session(store: InMemoryObjectStore(failingKeys: ["Originals/a.DNG"]), clock: clock)
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        session.backUpSoon()
        await session.pendingRun?.value
        let reads = sandbox.credentials.reads
        clock.advance(by: 1000)
        session.backUpSoon()
        await session.pendingRun?.value
        #expect(sandbox.credentials.reads == reads + 1)
    }

    private func edit(rating: Int) {
        try? sandbox.library.catalog.setRating(rating, for: [1])
    }

    @Test func backUpNowNeverWaits() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(), FakeClock())
        let session = await configured(store: store, clock: clock)
        session.backUpSoon()
        await session.pendingRun?.value
        await session.runNow()
        await session.runNow()
        #expect(clock.sleeps == [20] && store.runs == 3)
    }

    /// The run made by hand has taken what the waiting one was for.
    @Test func backUpNowReplacesTheRunThatWasWaiting() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(), FakeClock(holdsSleepers: true))
        let session = await configured(store: store, clock: clock)
        session.backUpSoon()
        let waiting = session.pendingRun
        await session.runNow()
        #expect(store.runs == 1 && session.pendingRun == nil)
        await clock.holdsSleepers?.open()
        await waiting?.value
        #expect(store.runs == 1)
    }

    /// An edit made while a run is going is not in it: the request is kept, not dropped.
    @Test func aRequestMadeDuringARunIsRememberedAndPaced() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(holdsRuns: true), FakeClock())
        let session = await configured(store: store, clock: clock)
        let run = Task { await session.runNow() }
        await store.entered.wait()
        edit(rating: 4)
        session.backUpSoon()
        session.backUpSoon()
        #expect(session.pendingRun == nil)

        await store.holdsRuns?.open()
        await run.value
        await session.pendingRun?.value
        #expect(store.runs == 2 && clock.sleeps == [300])
    }

    @Test func backUpNowDuringARunRunsAgainRightAfterIt() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(holdsRuns: true), FakeClock())
        let session = await configured(store: store, clock: clock)
        let run = Task { await session.runNow() }
        await store.entered.wait()
        await session.runNow()
        #expect(store.runs == 1)

        await store.holdsRuns?.open()
        await run.value
        #expect(store.runs == 2 && clock.sleeps.isEmpty && session.pendingRun == nil)
    }

    /// Quitting is the moment the last edits of a session would otherwise wait for the next
    /// launch: one pass goes out before the app does. It is never paced, and never waits for
    /// a pending run to come round.
    @Test func quittingSendsWhatIsLeft() async {
        defer { sandbox.cleanUp() }
        // The clock holds whoever waits: a run that is waiting for its turn cannot go out
        // on its own, so a second run can only be the one quitting made.
        let (store, clock) = (ObservedStore(), FakeClock(holdsSleepers: true))
        let session = await configured(store: store, clock: clock)
        await session.runNow()
        #expect(store.runs == 1)

        edit(rating: 3)
        session.backUpSoon()
        #expect(session.pendingRun != nil, "waiting for its turn, which quitting does not")
        await session.runBeforeQuitting()
        #expect(store.runs == 2 && session.pendingRun == nil)
        await clock.holdsSleepers?.open()
    }

    /// Nothing changed, or nothing set up: quitting costs nothing at all.
    @Test func quittingWithNothingToSendSendsNothing() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(), FakeClock())
        let bare = sandbox.session(store: store, clock: clock)
        await bare.runBeforeQuitting()
        #expect(store.runs == 0)

        let session = await configured(store: store, clock: clock)
        session.backUpSoon()
        await session.pendingRun?.value
        let reads = sandbox.credentials.reads
        await session.runBeforeQuitting()
        #expect(store.runs == 1 && sandbox.credentials.reads == reads, "the catalog has not moved")
    }

    /// A pass that will not end must not hold the app open for ever.
    @Test func quittingGivesUpOnARunThatDragsOn() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(holdsRuns: true), FakeClock())
        let session = await configured(store: store, clock: clock)
        edit(rating: 4)

        // The store holds every run it is given, so this can only return on its deadline.
        // Returning at all is the whole point: the suite's time limit catches a wait that
        // never ends, and how far the pass got by then is up to the machine.
        await session.runBeforeQuitting(within: .milliseconds(50))
        await store.holdsRuns?.open()
    }

    @Test func nothingIsScheduledWhileTheBackupIsOffOrNotSetUp() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(), FakeClock())
        let session = sandbox.session(store: store, clock: clock)
        session.backUpSoon()
        #expect(session.pendingRun == nil)

        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        session.isEnabled = false
        session.backUpSoon()
        #expect(session.pendingRun == nil && store.runs == 0)
    }
}
