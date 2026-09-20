import Backup
import Catalog
import Foundation
import Testing
@testable import SimpleRAWUI

/// A credential store that says how often, and from which thread, it was read: the Keychain
/// is slow and may prompt, so reads are part of the contract. It can also refuse to answer.
final class ObservedCredentialStore: CredentialStore, @unchecked Sendable {
    let inner = InMemoryCredentialStore()
    private let lock = NSLock()
    private var counts = (reads: 0, onMainThread: 0)
    private var refuses = false

    var reads: Int { lock.withLock { counts.reads } }
    var readsOnMainThread: Int { lock.withLock { counts.onMainThread } }
    /// What the Keychain does when the user clicks Deny: no answer, the item is still there.
    func refuseReads() { lock.withLock { refuses = true } }

    func credentials(for account: String) -> S3Credentials? {
        let onMain = Thread.isMainThread
        let refused = lock.withLock {
            counts.reads += 1
            if onMain { counts.onMainThread += 1 }
            return refuses
        }
        return refused ? nil : inner.credentials(for: account)
    }

    func save(_ credentials: S3Credentials, for account: String) throws { try inner.save(credentials, for: account) }
    func delete(account: String) { inner.delete(account: account) }
}

@MainActor
struct BackupSessionSandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-backupsession-\(UUID().uuidString)")
    let library: Library
    let store = InMemoryObjectStore()
    let credentials = ObservedCredentialStore()

    init() throws {
        library = try Library(root: root.appendingPathComponent("library"))
        let file = library.root.appendingPathComponent("Originals/a.DNG")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("aaa".utf8).write(to: file)
        try library.catalog.add(NewPhoto(
            relativePath: "Originals/a.DNG", fileName: "a.DNG", contentHash: BackupHash.sha256(of: file), captureDate: nil,
            camera: nil, lens: nil, iso: nil, exposureTime: nil, aperture: nil, focalLength: nil, width: 1, height: 1
        ))
    }

    /// - Parameter clock: the real one when `nil`; only automatic runs ever wait.
    func session(store: (any ObjectStore)? = nil, clock: FakeClock? = nil) -> BackupSession {
        let chosen = store ?? self.store
        return BackupSession(
            library: library,
            settingsFile: settingsFile,
            credentials: credentials,
            makeStore: { _, _ in chosen },
            pacing: BackupPacing(launchDelay: 20, minimumInterval: 300),
            connectionTimeout: 12,
            now: { clock?.now ?? Date() },
            sleep: { seconds in
                if let clock { await clock.sleep(seconds) } else { try? await Task.sleep(for: .seconds(seconds)) }
            }
        )
    }

    var configuration: S3Configuration {
        S3Configuration(endpoint: URL(string: "https://s3.example.com")!, region: "eu-west-3", bucket: "photos", prefix: "simpleraw")
    }

    var settingsFile: URL { root.appendingPathComponent("backup.json") }

    /// What the Keychain holds for the sandbox's destination, read behind the session's back.
    var storedKeys: S3Credentials? { credentials.inner.credentials(for: BackupSession.keysAccount(for: configuration)) }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// Some of these tests hold a run in the middle: a bug must fail them, not hang the suite.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct BackupSessionTests {
    let sandbox: BackupSessionSandbox

    init() throws {
        sandbox = try BackupSessionSandbox()
    }

    @Test func doesNothingUntilItIsConfigured() async {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        #expect(session.status == .notConfigured && !session.isConfigured)
        await session.runNow()
        #expect(session.status == .notConfigured)
    }

    @Test func savingSettingsKeepsTheSecretOutOfTheSettingsFile() async throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "very-secret")
        #expect(session.isConfigured && session.status == .idle)

        let file = try String(contentsOf: sandbox.root.appendingPathComponent("backup.json"), encoding: .utf8)
        #expect(file.contains("s3.example.com") && !file.contains("very-secret") && !file.contains("AKIA"))
        #expect(sandbox.storedKeys == S3Credentials(accessKey: "AKIA", secretKey: "very-secret"))
    }

    @Test func settingsSurviveARestart() async {
        defer { sandbox.cleanUp() }
        await sandbox.session().save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        let relaunched = sandbox.session()
        #expect(relaunched.configuration == sandbox.configuration && relaunched.isConfigured)
    }

    @Test func aRunReportsWhatItDid() async {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        await session.runNow()
        guard case .upToDate(let date, let uploaded) = session.status else {
            Issue.record("expected an up-to-date status, got \(session.status)"); return
        }
        #expect(uploaded == 2 && abs(date.timeIntervalSinceNow) < 5)

        await session.runNow()
        guard case .upToDate(_, let again) = session.status else { Issue.record("expected up to date"); return }
        #expect(again == 0)
    }

    @Test func aFailureIsShownNotSwallowed() async {
        defer { sandbox.cleanUp() }
        let failing = InMemoryObjectStore(failingKeys: ["Originals/a.DNG"])
        let session = sandbox.session(store: failing)
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        await session.runNow()
        guard case .failed(let message) = session.status else { Issue.record("expected a failure"); return }
        #expect(message.contains("a.DNG"))
    }

    @Test func turningTheBackupOffStopsItWithoutForgettingItsSettings() async {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        session.isEnabled = false
        await session.runNow()
        #expect(session.status == .disabled)
        #expect(sandbox.session().configuration == sandbox.configuration)
        #expect(!sandbox.session().isEnabled)
    }

    /// Setting the backup up is asking for it: the switch comes on with the first save, and
    /// after that it is the user's.
    @Test func theFirstSaveTurnsTheBackupOn() async {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        session.isEnabled = false
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        #expect(session.isEnabled && session.status == .idle && sandbox.session().isEnabled)

        session.isEnabled = false
        await session.save(sandbox.configuration, accessKey: nil, secretKey: nil)
        #expect(!session.isEnabled && session.status == .disabled)
    }

    /// The form never shows the stored keys; leaving them blank must not erase them, and
    /// needs no trip to the Keychain.
    @Test func blankKeysKeepTheStoredOnes() async {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        var moved = sandbox.configuration
        moved.prefix = "elsewhere"
        moved.region = "eu-west-1"
        #expect(await session.save(moved, accessKey: nil, secretKey: nil))
        #expect(session.configuration == moved)
        #expect(sandbox.storedKeys == S3Credentials(accessKey: "AKIA", secretKey: "secret"))
        #expect(sandbox.credentials.reads == 0)
    }

    /// Keys belong to the server and the bucket they were entered for: pointing the backup
    /// elsewhere with "unchanged" keys would send the library there under the old identity.
    @Test(arguments: ["https://s3.elsewhere.example", "https://s3.example.com:9000", "bucket"])
    func aNewDestinationNeedsTheKeysAgain(change: String) async {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        var moved = sandbox.configuration
        if let url = URL(string: change), url.scheme != nil { moved.endpoint = url } else { moved.bucket = "other" }

        #expect(await !session.save(moved, accessKey: nil, secretKey: nil))
        #expect(session.saveError == BackupSession.destinationChangedMessage)
        #expect(await session.testConnection(moved, accessKey: nil, secretKey: nil) == BackupSession.destinationChangedMessage)
        #expect(sandbox.credentials.reads == 0)
        #expect(session.configuration == sandbox.configuration)
        #expect(sandbox.session().configuration == sandbox.configuration)

        #expect(await session.save(moved, accessKey: "AKIA2", secretKey: "secret2"))
        #expect(session.configuration == moved && session.saveError == nil)
        let stored = sandbox.credentials.inner
        #expect(stored.credentials(for: BackupSession.keysAccount(for: moved)) == S3Credentials(accessKey: "AKIA2", secretKey: "secret2"))
        // Nothing is left behind in the Keychain for a destination that is no longer used.
        #expect(sandbox.storedKeys == nil)
    }

    /// The binding lives in the Keychain, not in the settings file, which any process of the
    /// user can edit: a file pointed elsewhere finds no keys.
    @Test func aSettingsFileEditedToPointElsewhereFindsNoKeys() async throws {
        defer { sandbox.cleanUp() }
        await sandbox.session().save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        let edited = try String(contentsOf: sandbox.settingsFile, encoding: .utf8).replacingOccurrences(of: "s3.example.com", with: "s3.evil.example")
        try edited.write(to: sandbox.settingsFile, atomically: true, encoding: .utf8)

        let session = sandbox.session()
        #expect(session.configuration?.endpoint.host == "s3.evil.example")
        await session.runNow()
        #expect(session.status == .failed(BackupSession.keysUnavailableMessage))
        #expect(try await sandbox.store.list(prefix: "").isEmpty)
    }

    /// Earlier versions kept the keys under one account, whatever the destination.
    @Test func keysSavedByAnEarlierVersionAreAdopted() async throws {
        defer { sandbox.cleanUp() }
        await sandbox.session().save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        let keys = try #require(sandbox.storedKeys)
        sandbox.credentials.inner.delete(account: BackupSession.keysAccount(for: sandbox.configuration))
        try sandbox.credentials.inner.save(keys, for: BackupSession.legacyKeysAccount)

        let session = sandbox.session()
        await session.runNow()
        guard case .upToDate = session.status else { Issue.record("expected a run, got \(session.status)"); return }
        #expect(sandbox.storedKeys == keys)
        #expect(sandbox.credentials.inner.credentials(for: BackupSession.legacyKeysAccount) == nil)
    }

    /// The two keys are stored as one item: half a pair cannot be saved.
    @Test func keysAreEnteredAsAPair() async {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        #expect(await !session.save(sandbox.configuration, accessKey: "AKIA", secretKey: nil))
        #expect(session.saveError != nil && !session.isConfigured)
        #expect(await !session.save(sandbox.configuration, accessKey: nil, secretKey: nil))
        #expect(session.saveError != nil && !session.isConfigured)
        #expect(await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret"))
        #expect(session.saveError == nil && session.isConfigured)
    }

    @Test func aLibraryCanBeRestoredFromItsBackup() async throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        await session.runNow()

        let destination = sandbox.root.appendingPathComponent("restored")
        let report = try #require(await session.restore(to: destination))
        #expect(session.lastRestore?.report == report && session.lastRestore?.folder == destination)
        #expect(report.downloaded == 2 && report.corrupted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Originals/a.DNG").path))
        // Never over an existing library.
        #expect(await session.restore(to: sandbox.library.root) == nil)
        #expect(session.restoreError != nil && session.lastRestore == nil)
    }

    /// Restoring is one of the long jobs of the session: one at a time, with its progress
    /// on the way and nothing left behind.
    @Test func aLongJobShowsItsProgressAndRunsAlone() async throws {
        defer { sandbox.cleanUp() }
        let store = ObservedStore(holdsDownloads: true)
        let session = sandbox.session(store: store)
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        // A run downloads too (the hash of the catalog): it goes around the held store.
        await sandbox.session(store: store.inner).runNow()

        let restore = Task { await session.restore(to: sandbox.root.appendingPathComponent("restored")) }
        await store.downloading.wait()
        for _ in 0..<1000 where session.runningJob?.total != 2 { await Task.yield() }
        #expect(session.runningJob == BackupSession.JobProgress(job: .restore, done: 0, total: 2) && session.isRestoring)
        #expect(await session.restore(to: sandbox.root.appendingPathComponent("elsewhere")) == nil)
        #expect(session.isRestoring && session.restoreError == nil)

        await store.holdsDownloads?.open()
        #expect(try #require(await restore.value).downloaded == 2)
        #expect(session.runningJob == nil && !session.isRestoring && session.error(of: .restore) == nil)
    }

    /// What went up is remembered next to the library: the store is not listed by every run.
    @Test func aRunRemembersWhatTheStoreHolds() async {
        defer { sandbox.cleanUp() }
        let store = ObservedStore()
        let session = sandbox.session(store: store)
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        await session.runNow()
        await session.runNow()
        #expect(store.runs == 2 && store.listings == 1)
        #expect(FileManager.default.fileExists(atPath: UploadManifest.defaultFile(in: sandbox.library).path))
    }

    @Test func theBackupCanBeVerified() async throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        await session.runNow()
        let report = try #require(await session.verify())
        #expect(report.isSound && report.checked == 2)
        #expect(session.runningJob == nil && session.error(of: .verify) == nil)
        // The window may have been closed in the meantime: what was found stays in the session.
        #expect(session.lastVerification == report)

        // Against a store that lost everything, the report says what is missing.
        let emptied = sandbox.session(store: InMemoryObjectStore())
        let missing = try #require(await emptied.verify()).missing
        #expect(missing.contains("Originals/a.DNG") && missing.contains("catalog.sqlite"))

        sandbox.credentials.refuseReads()
        let refused = sandbox.session()
        #expect(await refused.verify() == nil && refused.error(of: .verify) == BackupSession.keysUnavailableMessage)
    }

    /// The transport waits for the network for half an hour; somebody who clicked a button does not.
    @Test func aConnectionTestGivesUpAfterAFewSeconds() async {
        defer { sandbox.cleanUp() }
        let (store, clock) = (ObservedStore(holdsListings: true), FakeClock())
        let session = sandbox.session(store: store, clock: clock)
        let message = await session.testConnection(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        #expect(message == BackupSession.connectionTimeoutMessage(seconds: 12) && clock.sleeps == [12])
        await store.holdsListings?.open()
    }

    @Test func theConnectionCanBeTestedBeforeSaving() async {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        #expect(await session.testConnection(sandbox.configuration, accessKey: "AKIA", secretKey: "secret") == nil)
        let message = await session.testConnection(sandbox.configuration, accessKey: "", secretKey: nil)
        #expect(message != nil)
    }

    // MARK: - A settings file that cannot be trusted

    /// The file can be edited by anything: what the form would refuse is refused on load too,
    /// and the file is left as it is for whoever wants to look at it.
    @Test(arguments: ["ftp://s3.example.com", "https://someone:hunter2@s3.example.com", "https://s3.example.com/?x=1"])
    func anInvalidEndpointInTheSettingsFileIsNotUsed(endpoint: String) async throws {
        defer { sandbox.cleanUp() }
        let written = Data(#"{"configuration":{"bucket":"photos","endpoint":"\#(endpoint)","prefix":"simpleraw","region":"eu-west-3"},"isEnabled":true}"#.utf8)
        try written.write(to: sandbox.settingsFile)

        let session = sandbox.session()
        #expect(session.status == .notConfigured && session.configuration == nil)
        let problem = try #require(session.settingsProblem)
        #expect(!problem.contains("hunter2"))
        session.isEnabled = false
        await session.runNow()
        #expect(try Data(contentsOf: sandbox.settingsFile) == written)
        #expect(sandbox.credentials.reads == 0)
    }

    /// The bucket and the folder end up in URLs and keys: the file is not trusted for them either.
    @Test(arguments: [("My Photos", "simpleraw"), ("photos", "../elsewhere")])
    func invalidNamesInTheSettingsFileAreNotUsed(bucket: String, prefix: String) throws {
        defer { sandbox.cleanUp() }
        let written = Data(#"{"configuration":{"bucket":"\#(bucket)","endpoint":"https://s3.example.com","prefix":"\#(prefix)","region":"eu-west-3"},"isEnabled":true}"#.utf8)
        try written.write(to: sandbox.settingsFile)
        let session = sandbox.session()
        #expect(session.status == .notConfigured && session.configuration == nil && session.settingsProblem != nil)
        #expect(try Data(contentsOf: sandbox.settingsFile) == written)
    }

    @Test func savingRefusesAnEndpointTheFormWouldRefuse() async throws {
        defer { sandbox.cleanUp() }
        let session = sandbox.session()
        var configuration = sandbox.configuration
        configuration.endpoint = try #require(URL(string: "ftp://s3.example.com"))
        #expect(await !session.save(configuration, accessKey: "AKIA", secretKey: "secret"))
        #expect(session.saveError != nil && !session.isConfigured)
        #expect(!FileManager.default.fileExists(atPath: sandbox.settingsFile.path))
    }

    /// Unreadable is not "never set up": the file is kept aside instead of being overwritten
    /// by the next save, and the window says so.
    @Test func unreadableSettingsAreSetAsideAndReported() async throws {
        defer { sandbox.cleanUp() }
        let written = Data("{ \"configuration\": oops".utf8)
        try written.write(to: sandbox.settingsFile)

        let session = sandbox.session()
        #expect(session.status == .notConfigured)
        #expect(try #require(session.settingsProblem).contains("backup.unreadable.json"))
        let aside = sandbox.root.appendingPathComponent("backup.unreadable.json")
        #expect(try Data(contentsOf: aside) == written)
        #expect(!FileManager.default.fileExists(atPath: sandbox.settingsFile.path))

        #expect(await session.save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret"))
        #expect(session.settingsProblem == nil && session.isConfigured)
        #expect(try Data(contentsOf: aside) == written)
    }

    @Test func noSettingsFileIsNotAProblem() {
        defer { sandbox.cleanUp() }
        #expect(sandbox.session().settingsProblem == nil)
    }

    // MARK: - Keychain

    /// The Keychain is slow and may prompt: nothing reads it until a run needs the keys, and
    /// never on the main thread.
    @Test func theKeychainIsOnlyReadWhenARunNeedsTheKeys() async {
        defer { sandbox.cleanUp() }
        await sandbox.session().save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        let relaunched = sandbox.session()
        #expect(relaunched.isConfigured && relaunched.status == .idle)
        #expect(sandbox.credentials.reads == 0)

        await relaunched.runNow()
        guard case .upToDate = relaunched.status else { Issue.record("expected a run, got \(relaunched.status)"); return }
        #expect(sandbox.credentials.reads == 1 && sandbox.credentials.readsOnMainThread == 0)
    }

    @Test func keysThatCannotBeReadAreNotMistakenForAMissingSetup() async {
        defer { sandbox.cleanUp() }
        await sandbox.session().save(sandbox.configuration, accessKey: "AKIA", secretKey: "secret")
        sandbox.credentials.refuseReads()
        let session = sandbox.session()

        await session.runNow()
        #expect(session.status == .failed(BackupSession.keysUnavailableMessage) && session.isConfigured)
        #expect(await session.testConnection(sandbox.configuration, accessKey: nil, secretKey: nil) == BackupSession.keysUnavailableMessage)
        #expect(await session.restore(to: sandbox.root.appendingPathComponent("restored")) == nil)
        #expect(session.restoreError == BackupSession.keysUnavailableMessage)
        #expect(sandbox.credentials.readsOnMainThread == 0)
    }
}

/// Backup settings belong to the library they back up, not to the user: two libraries have
/// two destinations, and moving a library takes its settings with it.
@MainActor
@Suite struct BackupSettingsLocationTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-backuploc-\(UUID().uuidString)")

    private func library(_ name: String) throws -> Library {
        try Library(root: root.appendingPathComponent(name))
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @Test func theSettingsSitInTheLibrary() throws {
        defer { cleanUp() }
        let library = try library("one")
        #expect(BackupSession.settingsFile(in: library) == library.root.appendingPathComponent("backup.json"))
    }

    /// Earlier versions kept one file for the whole app. It is taken over by the first
    /// library that opens without settings of its own, and not left behind in two places.
    @Test func theOldGlobalSettingsAreTakenOverOnce() async throws {
        defer { cleanUp() }
        let global = root.appendingPathComponent("global/backup.json")
        try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)

        let first = try library("first")
        let written = BackupSession(library: first, settingsFile: BackupSession.settingsFile(in: first), credentials: InMemoryCredentialStore())
        await written.save(
            S3Configuration(endpoint: URL(string: "https://s3.example.com")!, region: "eu-west-3", bucket: "photos", prefix: "simpleraw"),
            accessKey: "AKIA", secretKey: "secret"
        )
        try FileManager.default.moveItem(at: BackupSession.settingsFile(in: first), to: global)

        let taken = try library("taken")
        BackupSession.takeOverGlobalSettings(for: taken, from: global)
        #expect(FileManager.default.fileExists(atPath: BackupSession.settingsFile(in: taken).path))
        #expect(!FileManager.default.fileExists(atPath: global.path), "not left in two places")

        // A library that already has its own keeps it, whatever is lying around.
        let other = try library("other")
        try Data(#"{"configuration": {}, "isEnabled": false}"#.utf8).write(to: BackupSession.settingsFile(in: other))
        try Data("{}".utf8).write(to: global)
        BackupSession.takeOverGlobalSettings(for: other, from: global)
        #expect(try String(contentsOf: BackupSession.settingsFile(in: other), encoding: .utf8).contains("isEnabled"))
        #expect(FileManager.default.fileExists(atPath: global.path), "someone else's settings are left alone")
    }
}
