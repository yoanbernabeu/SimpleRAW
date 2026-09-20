import Backup
import SwiftUI

/// Where the library is backed up, in the words of somebody who takes photos: the provider
/// is picked from a list, and the technical name of a field is in its help. Keys go to the
/// Keychain, the rest to a settings file. Everything that decides something lives in
/// `BackupForm`, `BackupSession` and `BackupSummary`.
public struct BackupSettingsView: View {
    @Bindable var session: BackupSession
    @State private var form = BackupForm(saved: nil)
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success
        case failure(String)
    }

    public init(session: BackupSession) {
        self.session = session
    }

    public var body: some View {
        Form {
            destinationSection
            keysSection
            submitSection
            if session.isConfigured {
                automaticSection
                jobsSection
            }
        }
        .formStyle(.grouped)
        .onAppear { form = BackupForm(saved: session.configuration) }
        .onChange(of: form) { testResult = nil }
    }

    // MARK: - Where

    private var destinationSection: some View {
        Section {
            if let problem = session.settingsProblem { Note(problem, isWarning: true) }
            Picker("Provider", selection: $form.provider) {
                ForEach(BackupProvider.allCases) { Text($0.name).tag($0) }
            }
            if form.provider.needsAccount {
                TextField("Account ID", text: $form.account, prompt: Text("From your Cloudflare dashboard"))
            }
            if form.provider == .other {
                TextField("Address", text: $form.endpoint, prompt: Text("https://storage.example.com"))
                    .help("The S3 endpoint of your server or provider")
                TextField("Region", text: $form.region, prompt: Text("us-east-1"))
                    .help("Leave us-east-1 unless your provider says otherwise")
            } else if form.provider.regions.count > 1 {
                Picker("Region", selection: $form.region) {
                    ForEach(form.provider.regions(including: form.region), id: \.self) { Text($0).tag($0) }
                }
                .help("Where your provider keeps the storage you created")
            }
            TextField("Storage name (bucket)", text: $form.storageName, prompt: Text("my-photos"))
                .help("The bucket you created at your provider")
            TextField("Folder", text: $form.folder)
                .help("A folder inside the storage (prefix), so that it can hold something else too")
            if let problem = form.visibleProblem { Note(problem.errorDescription ?? "", isWarning: true) }
            if form.isInsecure {
                Note("Not encrypted: over http, your photos travel in clear text. Use https unless this server is on your own network.", systemImage: "lock.open.fill", isWarning: true)
            }
        } header: {
            VStack(alignment: .leading, spacing: 14) {
                Text("Keeps a copy of your originals, edits and catalog on storage you control.")
                    .font(.body).fontWeight(.regular).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Where Your Photos Go")
            }
        } footer: {
            Footnote("Photos are stored as they are: use a private bucket, and turn on encryption and versioning at your provider.")
        }
    }

    // MARK: - Keys

    private var keysSection: some View {
        Section {
            TextField("Access key", text: $form.accessKey, prompt: Text(session.isConfigured ? "Unchanged" : ""))
                .help("The access key ID your provider gave you")
            SecureField("Secret key", text: $form.secretKey, prompt: Text(session.isConfigured ? "Unchanged" : ""))
                .help("The secret access key that came with it")
            if form.keys(saved: session.configuration) == .neededAgain {
                Note(BackupSession.destinationChangedMessage, isWarning: true)
            }
        } header: {
            Text("Keys")
        } footer: {
            Footnote("Kept in your Keychain, never in a file.")
        }
    }

    private var submitSection: some View {
        Section {
            HStack {
                Button("Test Connection", action: test).disabled(!canSubmit || isTesting)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            // On a line of their own: an answer from a server is rarely short.
            switch testResult {
            case .success: Note("Connected: SimpleRAW can reach your storage.", systemImage: "checkmark.circle.fill", isWarning: false)
            case .failure(let message): Note(message, isWarning: true)
            case nil: EmptyView()
            }
            if let problem = session.saveError { Note(problem, isWarning: true) }
        }
    }

    // MARK: - Once it is set up

    private var automaticSection: some View {
        Section {
            Toggle("Back Up Automatically", isOn: $session.isEnabled)
            HStack(alignment: .firstTextBaseline) {
                BackupStatusLabel(status: session.status)
                Spacer()
                Button("Back Up Now") { Task { await session.runNow() } }.disabled(!session.isEnabled || isRunning)
            }
        } footer: {
            Footnote("After an import and when you come back from editing, a few minutes apart. Nothing is ever deleted from your storage.")
        }
    }

    private var jobsSection: some View {
        Section {
            JobRow(title: "Verify Backup", job: .verify, session: session) { Task { await session.verify() } }
            if let report = session.lastVerification {
                Note(BackupSummary.verification(report), systemImage: report.isSound ? "checkmark.circle.fill" : nil, isWarning: !report.isSound)
            } else if let error = session.error(of: .verify) {
                Note(error, isWarning: true)
            }
            JobRow(title: "Restore Library…", job: .restore, session: session, action: restore)
            if let restored = session.lastRestore {
                let isIntact = BackupSummary.isIntact(restored.report)
                Note(BackupSummary.restore(restored.report, folder: restored.folder.lastPathComponent), systemImage: isIntact ? "checkmark.circle.fill" : nil, isWarning: !isIntact)
            } else if let error = session.restoreError {
                Note(error, isWarning: true)
            }
        } footer: {
            Footnote("Verify compares your library with what your storage holds, without downloading anything. Restore downloads your backup into an empty folder and checks every original: it never touches an existing library.")
        }
    }

    // MARK: - Actions

    private var canSubmit: Bool { form.canSubmit(saved: session.configuration) }

    private var isRunning: Bool {
        if case .running = session.status { return true }
        return false
    }

    private func save() {
        guard let configuration = try? form.configuration.get() else { return }
        Task {
            guard await session.save(configuration, accessKey: form.accessKey, secretKey: form.secretKey) else { return }
            form = BackupForm(saved: session.configuration)
        }
    }

    private func test() {
        guard let configuration = try? form.configuration.get() else { return }
        isTesting = true
        testResult = nil
        Task {
            let message = await session.testConnection(configuration, accessKey: form.accessKey, secretKey: form.secretKey)
            testResult = message.map(TestResult.failure) ?? .success
            isTesting = false
        }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose an empty folder to restore your library into."
        panel.prompt = "Restore Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await session.restore(to: folder) }
    }
}

/// The button of a long job, with how far the job is next to it while it runs.
private struct JobRow: View {
    let title: String
    let job: BackupSession.Job
    let session: BackupSession
    let action: () -> Void

    var body: some View {
        HStack {
            Button(title, action: action).disabled(session.runningJob != nil)
            if let progress = session.runningJob, progress.job == job {
                ProgressView().controlSize(.small)
                Text(BackupSummary.progress(progress)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
        }
    }
}

/// A line of its own under a field or a button: never truncated.
private struct Note: View {
    let text: String
    let systemImage: String
    let isWarning: Bool

    init(_ text: String, systemImage: String? = nil, isWarning: Bool) {
        self.text = text
        self.systemImage = systemImage ?? "exclamationmark.triangle.fill"
        self.isWarning = isWarning
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(isWarning ? Theme.warning : Theme.accent)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// One line saying how the backup is doing. The icons are drives, not clouds: the backup
/// goes to storage of one's own, not to iCloud.
struct BackupStatusLabel: View {
    let status: BackupSession.Status

    var body: some View {
        Label(text, systemImage: icon).foregroundStyle(color).font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    var icon: String {
        switch status {
        case .notConfigured: "externaldrive.badge.questionmark"
        case .disabled: "externaldrive.badge.minus"
        case .idle: "externaldrive"
        case .running: "arrow.up.circle"
        case .upToDate: "externaldrive.badge.checkmark"
        case .failed: "externaldrive.badge.exclamationmark"
        }
    }

    private var color: Color {
        if case .failed = status { return Theme.warning }
        return .secondary
    }

    var text: String {
        switch status {
        case .notConfigured: "Backup is not set up"
        case .disabled: "Backup is off"
        case .idle: "Backup is ready"
        case .running(let done, let total):
            total == 0 ? "Checking what to back up…" : "Backing up \(BackupSummary.number(min(done + 1, total))) of \(BackupSummary.number(total))…"
        case .upToDate(let date, let uploaded):
            "Backed up at \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_US"))))"
                + (uploaded > 0 ? ", \(BackupSummary.counted(uploaded, "new file"))" : "")
        case .failed(let message): message
        }
    }
}
