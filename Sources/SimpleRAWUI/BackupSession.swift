import Backup
import Catalog
import Foundation
import Observation

/// State of the backup: where it goes, whether it is on, and how the last run went.
@MainActor
@Observable
public final class BackupSession {
    public enum Status: Equatable, Sendable {
        case notConfigured
        case disabled
        case idle
        case running(done: Int, total: Int)
        case upToDate(Date, uploaded: Int)
        case failed(String)
    }

    public private(set) var status = Status.notConfigured
    public private(set) var configuration: S3Configuration?
    /// Why the last `save` was refused, in words the settings window can show.
    public private(set) var saveError: String?
    /// Why the settings found at launch are not used. Cleared by the next successful save.
    public private(set) var settingsProblem: String?
    /// Off keeps the settings but stops every run.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            persist()
            refreshIdleStatus()
        }
    }

    /// A saved configuration means keys were saved with it: `save` writes the keys first.
    /// The Keychain itself is only read when a run needs the keys, off the main actor: it is
    /// slow, and it may prompt.
    public var isConfigured: Bool { configuration != nil }

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let settingsFile: URL
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let makeStore: @Sendable (S3Configuration, S3Credentials) -> any ObjectStore

    /// Keys are filed under the server and the bucket they were entered for, so that they can
    /// never sign requests to another one: the settings file, which any process of the user
    /// can edit, decides nothing about which keys are used.
    nonisolated static func keysAccount(for configuration: S3Configuration) -> String {
        let host = (configuration.endpoint.host ?? "").lowercased()
        let server = configuration.endpoint.port.map { "\(host):\($0)" } ?? host
        return "\(legacyKeysAccount)|\(server)|\(configuration.bucket)"
    }

    /// Where earlier versions kept the keys, whatever the destination.
    nonisolated static let legacyKeysAccount = "simpleraw-backup"

    /// What goes in the settings file: never a key.
    private struct Settings: Codable {
        var configuration: S3Configuration
        var isEnabled: Bool
    }

    @ObservationIgnored private let pacing: BackupPacing
    @ObservationIgnored private let connectionTimeout: TimeInterval
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private let launchedAt: Date

    /// - Parameters:
    ///   - makeStore: how to reach a configured store; S3, unless a test says otherwise.
    ///   - pacing, now, sleep: when automatic runs start; tests bring their own clock.
    ///   - connectionTimeout: how long "Test Connection" waits for an answer.
    public init(
        library: Library,
        settingsFile: URL = BackupSession.defaultSettingsFile,
        credentials: any CredentialStore = KeychainCredentialStore(),
        makeStore: @escaping @Sendable (S3Configuration, S3Credentials) -> any ObjectStore = { S3Client(configuration: $0, credentials: $1) },
        pacing: BackupPacing = BackupPacing(),
        connectionTimeout: TimeInterval = 12,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.library = library
        self.settingsFile = settingsFile
        self.credentials = credentials
        self.makeStore = makeStore
        self.pacing = pacing
        self.connectionTimeout = connectionTimeout
        self.now = now
        self.sleep = sleep
        launchedAt = now()
        load()
        refreshIdleStatus()
    }

    /// Where a library keeps its backup settings: inside itself. They belong to the library
    /// they back up — two libraries have two destinations — and moving a library takes them
    /// with it. Never a key: those are the Keychain's.
    ///
    /// It sits at the root, which no backup uploads: only `Originals`, `Exports` and the
    /// catalog go up.
    public static func settingsFile(in library: Library) -> URL {
        library.root.appendingPathComponent("backup.json")
    }

    /// Where earlier versions kept one file for the whole app.
    public static var defaultSettingsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimpleRAW/backup.json")
    }

    /// Moves the settings of an earlier version into the library, once: the first library
    /// that opens without settings of its own takes them over. A library that already has
    /// its own is left alone, and so is the old file in that case — it may belong to another
    /// library, which will take it over itself.
    public static func takeOverGlobalSettings(for library: Library, from global: URL = BackupSession.defaultSettingsFile) {
        let own = settingsFile(in: library)
        guard !FileManager.default.fileExists(atPath: own.path),
              FileManager.default.fileExists(atPath: global.path) else { return }
        try? FileManager.default.moveItem(at: global, to: own)
    }

    // MARK: - Settings

    /// The settings file can be edited by anything: it is checked like what the form takes.
    /// A file that cannot be used never passes for "not set up yet", to be overwritten in
    /// silence: an invalid one is left alone, an unreadable one is set aside.
    private func load() {
        guard let data = try? Data(contentsOf: settingsFile) else { return }
        do {
            let settings: Settings
            do { settings = try JSONDecoder().decode(Settings.self, from: data) } catch { throw Unreadable() }
            configuration = try settings.configuration.validated()
            isEnabled = settings.isEnabled
        } catch is Unreadable {
            setAsideUnreadableSettings()
        } catch {
            // `S3Endpoint.Problem` or `S3Naming.Problem`: both explain themselves.
            settingsProblem = "The saved backup settings cannot be used, so the backup is off. \(error.localizedDescription) Set the backup up again."
        }
    }

    private struct Unreadable: Error {}

    private func setAsideUnreadableSettings() {
        let aside = settingsFile.deletingLastPathComponent().appendingPathComponent(Self.unreadableSettingsName)
        try? FileManager.default.removeItem(at: aside)
        let kept = (try? FileManager.default.moveItem(at: settingsFile, to: aside)) != nil
        settingsProblem = "Your backup settings could not be read, so the backup is off. "
            + (kept ? "They were kept as \(Self.unreadableSettingsName). " : "") + "Set the backup up again."
    }

    static let unreadableSettingsName = "backup.unreadable.json"

    /// The Keychain holds keys, but would not hand them over: access denied, prompt cancelled,
    /// or the item removed behind our back. Not the same thing as a backup never set up.
    public static let keysUnavailableMessage =
        "SimpleRAW could not read your keys from the Keychain. Allow access when macOS asks, or enter the keys again in Settings."

    public static let destinationChangedMessage = "Enter the access key and the secret key again: the destination changed."

    /// The configuration goes to the settings file; the keys go to the Keychain, and nowhere else.
    /// - Parameters:
    ///   - accessKey, secretKey: both `nil` (or blank) keeps the pair already in the Keychain,
    ///     without reading it, which only the same server and bucket may do. They are one
    ///     Keychain item: half a pair is refused.
    /// - Returns: whether the settings were saved; `saveError` says why they were not.
    @discardableResult
    public func save(_ configuration: S3Configuration, accessKey: String?, secretKey: String?) async -> Bool {
        var configuration = configuration
        saveError = nil
        let keys: S3Credentials?
        switch (Self.filled(accessKey), Self.filled(secretKey)) {
        case (let accessKey?, let secretKey?): keys = S3Credentials(accessKey: accessKey, secretKey: secretKey)
        case (nil, nil) where isConfigured:
            guard keepsDestination(configuration) else { return refuse(Self.destinationChangedMessage) }
            keys = nil
        default: return refuse("Enter both the access key and the secret key.")
        }
        do {
            // Same check as the form: the session does not rely on its callers for it.
            configuration = try configuration.validated()
            if let keys {
                let credentials = credentials
                let account = Self.keysAccount(for: configuration)
                // Keys of a destination that is no longer used have no reason to stay around.
                let forgotten = ([Self.legacyKeysAccount] + (self.configuration.map { [Self.keysAccount(for: $0)] } ?? [])).filter { $0 != account }
                try await Task.detached {
                    try credentials.save(keys, for: account)
                    forgotten.forEach(credentials.delete)
                }.value
            }
            // Setting the backup up is asking for it; afterwards the switch is the user's.
            let isFirstSave = self.configuration == nil
            try write(Settings(configuration: configuration, isEnabled: isFirstSave || isEnabled))
            if isFirstSave { isEnabled = true }
        } catch {
            return refuse(error.localizedDescription)
        }
        self.configuration = configuration
        settingsProblem = nil
        refreshIdleStatus()
        return true
    }

    /// Whether the keys in the Keychain were entered for this server and this bucket.
    public func keepsDestination(_ configuration: S3Configuration) -> Bool {
        self.configuration.map(Self.keysAccount) == Self.keysAccount(for: configuration)
    }

    private func refuse(_ reason: String) -> Bool {
        saveError = reason
        return false
    }

    private static func filled(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `nil` when the store answers; what went wrong otherwise. Nothing is saved.
    /// - Parameters:
    ///   - accessKey, secretKey: both `nil` (or blank) tests with the pair in the Keychain.
    public func testConnection(_ configuration: S3Configuration, accessKey: String?, secretKey: String?) async -> String? {
        let keys: S3Credentials
        switch (Self.filled(accessKey), Self.filled(secretKey)) {
        case (let accessKey?, let secretKey?): keys = S3Credentials(accessKey: accessKey, secretKey: secretKey)
        case (nil, nil) where isConfigured:
            guard keepsDestination(configuration) else { return Self.destinationChangedMessage }
            guard let stored = await storedKeys(for: configuration) else { return Self.keysUnavailableMessage }
            keys = stored
        default: return "An access key and a secret key are needed."
        }
        let store = makeStore(configuration, keys)
        return await Self.firstAnswer(within: connectionTimeout, sleep: sleep) {
            do {
                _ = try await store.list(prefix: "")
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    public nonisolated static func connectionTimeoutMessage(seconds: TimeInterval) -> String {
        "The storage did not answer within \(Int(seconds)) seconds. Check your internet connection and the provider you chose, then try again."
    }

    /// The transport waits for the network for up to half an hour, which suits a backup in
    /// the background, not somebody who clicked a button: whichever comes first, the answer
    /// or the timeout, is the result, and the other is cancelled.
    private nonisolated static func firstAnswer(
        within timeout: TimeInterval, sleep: @escaping @Sendable (TimeInterval) async -> Void,
        _ attempt: @escaping @Sendable () async -> String?
    ) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            let attempting = Task.detached { once.resume(with: await attempt()) }
            let waiting = Task.detached {
                await sleep(timeout)
                guard !Task.isCancelled else { return }
                attempting.cancel()
                once.resume(with: connectionTimeoutMessage(seconds: timeout))
            }
            once.onResume { waiting.cancel() }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        private var cleanUp: (@Sendable () -> Void)?
        private var isDone = false

        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

        func resume(with value: String?) {
            let (pending, cleanUp) = lock.withLock {
                defer { (continuation, self.cleanUp, isDone) = (nil, nil, true) }
                return (continuation, self.cleanUp)
            }
            pending?.resume(returning: value)
            cleanUp?()
        }

        /// Runs at once if the answer is already there.
        func onResume(_ action: @escaping @Sendable () -> Void) {
            let runNow = lock.withLock {
                if !isDone { cleanUp = action }
                return isDone
            }
            if runNow { action() }
        }
    }

    private func persist() {
        guard let configuration else { return }
        do {
            try write(Settings(configuration: configuration, isEnabled: isEnabled))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func write(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsFile, options: .atomic)
    }

    // MARK: - Running

    private enum Request {
        case automatic, byHand
    }

    /// The automatic run that is waiting for its turn. Tests wait on it.
    @ObservationIgnored private(set) var pendingRun: Task<Void, Never>?
    /// Asked for while a run was going: what changed since may not be in that run.
    @ObservationIgnored private var requestedDuringRun: Request?
    @ObservationIgnored private var lastRunEndedAt: Date?
    /// The revision of the catalog a run of this session sent without a failure, and where:
    /// an automatic run has nothing to do while the catalog has not moved since. Imports and
    /// edits all move it.
    @ObservationIgnored private var lastSent: (revision: Int64, destination: String)?

    /// Backs up now, because the user asked: never paced. Asked during a run, it runs again
    /// as soon as that one ends. Does nothing while the backup is off or not configured.
    public func runNow() async {
        // This run takes what the waiting one was for.
        pendingRun?.cancel()
        pendingRun = nil
        await run(.byHand)
    }

    /// One last pass before the app goes. Quitting is the moment the edits of a whole session
    /// would otherwise wait for the next launch, so this is never paced: whatever was waiting
    /// for its turn goes out now.
    ///
    /// Bounded on purpose: an upload that drags on must not hold the app open. What does not
    /// make it is sent at the next launch — the store already knows what it has.
    public func runBeforeQuitting(within limit: Duration = .seconds(20)) async {
        pendingRun?.cancel()
        pendingRun = nil
        guard isConfigured, isEnabled, await hasSomethingToSend() else { return }
        // Whichever comes first opens the latch. The pass is not waited for beyond that: an
        // upload held by a server that never answers cannot be cancelled, only left behind.
        let latch = Latch()
        let pass = Task { [weak self] in
            await self?.run(.automatic)
            await latch.open()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            await latch.open()
        }
        await latch.wait()
        timer.cancel()
        _ = pass
    }

    /// Opens once, and lets through everyone waiting. What a race between a job and a
    /// deadline needs, without waiting for the loser.
    private actor Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Whether the library has moved since what was last sent to this destination. The same
    /// question an automatic run asks before waking the Keychain.
    private func hasSomethingToSend() async -> Bool {
        guard let configuration else { return false }
        let library = library
        guard let revision = await Task.detached(operation: { try? library.catalog.revision }).value,
              let lastSent else { return true }
        return lastSent != (revision, configuration.destinationIdentity)
    }

    /// Backs up in a while, because something changed: edits, imports, the launch. Requests
    /// are merged into one run, which starts when `BackupPacing` allows.
    public func backUpSoon() {
        guard isConfigured, isEnabled else { return }
        if case .running = status {
            requestedDuringRun = requestedDuringRun ?? .automatic
            return
        }
        guard pendingRun == nil else { return }
        let wait = pacing.delay(now: now(), launchedAt: launchedAt, lastRunEndedAt: lastRunEndedAt)
        pendingRun = Task { [weak self, sleep] in
            if wait > 0 { await sleep(wait) }
            guard let self, !Task.isCancelled else { return }
            self.pendingRun = nil
            await self.run(.automatic)
        }
    }

    private func run(_ request: Request) async {
        if case .running = status {
            if request == .byHand || requestedDuringRun == nil { requestedDuringRun = request }
            return
        }
        var request = request
        repeat {
            requestedDuringRun = nil
            if await pass(request) { lastRunEndedAt = now() }
            request = .byHand
        } while requestedDuringRun == .byHand
        if requestedDuringRun == .automatic {
            requestedDuringRun = nil
            backUpSoon()
        }
    }

    /// Uploads what the store does not have yet, off the main actor.
    /// - Returns: whether this was a run, which the next automatic one keeps its distance from.
    private func pass(_ request: Request) async -> Bool {
        guard let configuration, isEnabled else { return false }
        // Read before the run: what changes during it belongs to the next one.
        let library = library
        let revision = await Task.detached { try? library.catalog.revision }.value
        let destination = configuration.destinationIdentity
        if request == .automatic, let revision, let lastSent, lastSent == (revision, destination) { return false }

        status = .running(done: 0, total: 0)
        guard let keys = await storedKeys(for: configuration) else {
            status = .failed(Self.keysUnavailableMessage)
            // Paced like a run: the Keychain must not prompt at every trip back to the grid.
            return true
        }
        let backup = Self.backup(of: library, on: makeStore(configuration, keys), for: configuration)
        let report = await Task.detached(priority: .utility) { [weak self] in
            await backup.run { progress in
                Task { @MainActor in
                    guard let self, case .running = self.status else { return }
                    self.status = .running(done: progress.done, total: progress.total)
                }
            }
        }.value

        if let failure = report.failures.first {
            status = .failed(BackupSummary.failure(count: report.failures.count, firstKey: failure.key, firstError: failure.error))
            lastSent = nil
        } else {
            status = .upToDate(Date(), uploaded: report.uploaded.count)
            lastSent = revision.map { ($0, destination) }
        }
        return true
    }

    /// A backup that remembers, next to the library, what it already sent to this destination:
    /// a run does not start by listing the whole store.
    private nonisolated static func backup(of library: Library, on store: any ObjectStore, for configuration: S3Configuration) -> LibraryBackup {
        let manifest = UploadManifest(file: UploadManifest.defaultFile(in: library), destination: configuration.destinationIdentity)
        return LibraryBackup(library: library, store: store, manifest: manifest)
    }

    // MARK: - Long jobs

    /// What the session can do with the backup besides running it. Each is one entry here
    /// and one function made of a call to `perform`: the keys, the hop off the main actor,
    /// the progress and the error are shared.
    public enum Job: Hashable, Sendable {
        case restore, verify
    }

    public struct JobProgress: Equatable, Sendable {
        public let job: Job
        public var done = 0
        /// Zero until the job knows how much there is to do.
        public var total = 0
    }

    /// The long job that is going, if any: they run one at a time.
    public private(set) var runningJob: JobProgress?
    private var jobErrors: [Job: String] = [:]

    /// Why the last run of this job failed; `nil` once it is started again.
    public func error(of job: Job) -> String? { jobErrors[job] }

    public var isRestoring: Bool { runningJob?.job == .restore }
    public var restoreError: String? { error(of: .restore) }

    public struct Restored: Equatable, Sendable {
        public let report: RestoreReport
        public let folder: URL
    }

    /// What the last restore and the last verification of this session found. They live here,
    /// not in the window: a long job goes on when the window is closed.
    public private(set) var lastRestore: Restored?
    public private(set) var lastVerification: VerificationReport?

    /// Rebuilds the library from its backup into an empty folder, never over an existing
    /// library, and checks every original. `nil` when it could not be done; see `restoreError`.
    @discardableResult
    public func restore(to destination: URL) async -> RestoreReport? {
        guard runningJob == nil else { return nil }
        lastRestore = nil
        let report = await perform(.restore) { store, _, progress in
            try await LibraryBackup.restore(from: store, to: destination, progress: progress)
        }
        lastRestore = report.map { Restored(report: $0, folder: destination) }
        return report
    }

    /// Compares the library with what the store holds, without downloading anything. `nil`
    /// when it could not be done; see `error(of: .verify)`.
    @discardableResult
    public func verify() async -> VerificationReport? {
        guard runningJob == nil else { return nil }
        lastVerification = nil
        let library = library
        lastVerification = await perform(.verify) { store, configuration, progress in
            try await Self.backup(of: library, on: store, for: configuration).verify(progress: progress)
        }
        return lastVerification
    }

    /// Runs a long job off the main actor, with the stored keys. `nil` when it failed, see
    /// `error(of:)`, or when another job is going.
    private func perform<Report: Sendable>(
        _ job: Job,
        _ work: @escaping @Sendable (any ObjectStore, S3Configuration, @escaping @Sendable (BackupProgress) -> Void) async throws -> Report
    ) async -> Report? {
        guard let configuration, runningJob == nil else { return nil }
        runningJob = JobProgress(job: job)
        jobErrors[job] = nil
        defer { runningJob = nil }
        guard let keys = await storedKeys(for: configuration) else {
            jobErrors[job] = Self.keysUnavailableMessage
            return nil
        }
        let store = makeStore(configuration, keys)
        do {
            return try await Task.detached(priority: .userInitiated) { [weak self] in
                try await work(store, configuration) { progress in
                    Task { @MainActor in
                        guard let self, self.runningJob?.job == job else { return }
                        self.runningJob = JobProgress(job: job, done: progress.done, total: progress.total)
                    }
                }
            }.value
        } catch {
            jobErrors[job] = error.localizedDescription
            return nil
        }
    }

    /// The one place that reads the Keychain: when a run, a test or a restore needs the keys,
    /// and never on the main actor.
    private func storedKeys(for configuration: S3Configuration) async -> S3Credentials? {
        let credentials = credentials
        let account = Self.keysAccount(for: configuration)
        return await Task.detached {
            if let keys = credentials.credentials(for: account) { return keys }
            // Keys saved by an earlier version move under their destination, once.
            guard let legacy = credentials.credentials(for: Self.legacyKeysAccount),
                  (try? credentials.save(legacy, for: account)) != nil else { return nil }
            credentials.delete(account: Self.legacyKeysAccount)
            return legacy
        }.value
    }

    /// The resting status, when no run has happened in this session.
    private func refreshIdleStatus() {
        if case .running = status { return }
        if !isConfigured { status = .notConfigured } else if !isEnabled { status = .disabled } else if case .upToDate = status {} else { status = .idle }
    }
}
