import Catalog
import SwiftUI

/// The Settings window: where the library is, and where it is backed up. Dark and amber
/// like the rest of the app, whatever the system appearance.
public struct SettingsView: View {
    let app: AppSession
    /// The tab last looked at; also what `-settingsTab backup` opens from a script.
    @AppStorage("settingsTab") private var tab = Tab.library

    enum Tab: String {
        case library, backup
    }

    /// What happens once another folder is picked; the app reopens on it. `nil` in a
    /// preview or a test: the button then says what it would do and does nothing.
    let chooseLocation: ((URL) -> Void)?

    public init(app: AppSession, chooseLocation: ((URL) -> Void)? = nil) {
        self.app = app
        self.chooseLocation = chooseLocation
    }

    public var body: some View {
        TabView(selection: $tab) {
            LibrarySettingsView(library: app.library.library, chooseLocation: chooseLocation)
                .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                .tag(Tab.library)
            if let backup = app.backup {
                BackupSettingsView(session: backup)
                    .tabItem { Label("Backup", systemImage: "externaldrive") }
                    .tag(Tab.backup)
            }
        }
        .frame(width: Theme.settingsWidth, height: tab == .backup ? Theme.backupSettingsHeight : Theme.librarySettingsHeight)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .environment(\.locale, Locale(identifier: "en_US"))
    }
}

/// Where the library is and how much it holds.
struct LibrarySettingsView: View {
    let library: Library
    let chooseLocation: ((URL) -> Void)?
    @State private var footprint: LibraryFootprint?

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text((library.root.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Contents") {
                    if let footprint { Text(footprint.text) } else { ProgressView().controlSize(.small) }
                }
                HStack {
                    Spacer()
                    if let chooseLocation {
                        Button("Change Location…") { pickFolder(then: chooseLocation) }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
                }
            } footer: {
                Text("Originals, catalog and previews live in this one folder. Leave it to SimpleRAW: import and remove photos from the app. Changing the location opens another library there — it never moves this one.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // Walking the folder takes a while on a large library: never on the main actor.
        .task {
            let library = library
            footprint = await Task.detached(priority: .utility) { LibraryFootprint.measure(library) }.value
        }
    }
}

extension LibrarySettingsView {
    /// Asks for a folder, and hands it over. Choosing a folder that already holds a library
    /// opens that one; choosing an empty one starts a library there. Nothing is ever moved:
    /// a photo library is hundreds of gigabytes, and the Finder moves folders better than
    /// any app can.
    func pickFolder(then use: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = library.root.deletingLastPathComponent()
        panel.message = "Choose a folder for your library. SimpleRAW opens the library there, or starts one."
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let folder = panel.url, folder != library.root else { return }
        use(folder)
    }
}
