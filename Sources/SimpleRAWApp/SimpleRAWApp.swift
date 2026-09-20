import AppKit
import Catalog
import RawEngine
import SimpleRAWUI
import SwiftUI

@main
struct SimpleRAWApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var launch = SimpleRAWApp.makeSession()

    private var app: AppSession? { try? launch.get() }

    /// The delegate holds the session so that quitting can save and back up: `App` has no
    /// hook that runs before the process goes.
    private func handOverToDelegate(_ app: AppSession) {
        delegate.app = app
    }

    var body: some Scene {
        Window("SimpleRAW", id: "main") {
            Group {
                switch launch {
                case .success(let app):
                    RootView(app: app)
                        .onAppear {
                            handOverToDelegate(app)
                            applyLaunchArguments(to: app)
                            app.backUpSoon()
                        }
                case .failure(let error):
                    LibraryUnavailableView(location: SimpleRAWApp.libraryRoot, error: error) {
                        launch = SimpleRAWApp.makeSession()
                    } chooseLocation: { folder in
                        SimpleRAWApp.moveLibrary(to: folder)
                        launch = SimpleRAWApp.makeSession()
                    }
                }
            }
            .preferredColorScheme(.dark)
            // The interface is in English for now: numbers and dates follow, rather than mix
            // "Exposure" with "0,80".
            .environment(\.locale, SimpleRAWApp.interfaceLocale)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            if let app { AppCommands(app: app) }
        }

        Settings {
            if let app {
                SettingsView(app: app) { folder in
                    // The app reopens on the chosen folder; nothing is moved. Edits in
                    // flight are written first, as when quitting.
                    app.develop.flush()
                    SimpleRAWApp.moveLibrary(to: folder)
                    launch = SimpleRAWApp.makeSession()
                }
            }
        }
    }

    private static let interfaceLocale = Locale(identifier: "en_US")
    private static let arguments = LaunchArguments()
    /// The folder the photographer chose, and the right to open it. Made once: resolving a
    /// bookmark takes the right, and taking it twice leaks one.
    @MainActor private static let location = LibraryLocation()

    /// `-library path` for this launch, else the folder chosen before, else `~/Pictures`.
    ///
    /// The last of those only works outside the sandbox. Inside it the app may open what the
    /// person picked and nothing else, so a first launch finds no library, shows
    /// `LibraryUnavailableView` and asks — which is the right first question anyway.
    @MainActor private static var libraryRoot: URL {
        arguments.url(for: "library") ?? location.url ?? Library.defaultRoot
    }

    /// Keeps the folder and the right to it, then opens on it.
    @MainActor private static func moveLibrary(to folder: URL) {
        location.remember(folder)
    }

    /// The reason is kept: "this catalog was written by a newer version" is not "disk is read-only".
    private static func makeSession() -> Result<AppSession, Error> {
        Result {
            let library = try Library(root: libraryRoot)
            // Settings written by an earlier version, when there was one file for the app.
            BackupSession.takeOverGlobalSettings(for: library)
            return AppSession(
                library: library,
                backup: BackupSession(library: library, settingsFile: BackupSession.settingsFile(in: library))
            )
        }
    }

    /// `SimpleRAWApp [-library path] [-file photo.dng] [-look look.json] [-crop YES] …`
    ///
    /// These are `-key value` pairs on purpose: a bare path would become an "open document"
    /// event, which an unbundled SwiftUI app answers by not opening any window. Finder
    /// integration comes with the app bundle.
    private func applyLaunchArguments(to app: AppSession) {
        let arguments = SimpleRAWApp.arguments
        // Started first, and waits for the photo itself: a script given no file must say so
        // rather than sit there.
        GestureScript.begin(arguments, on: app)
        guard let file = arguments.url(for: "file") else { return }
        app.openFile(file)
        let session = app.develop
        if let look = arguments.url(for: "look") {
            do {
                session.adjustments = try Adjustments(contentsOf: look)
            } catch {
                session.report(error, title: "This look could not be read")
            }
        }
        session.isCropping = arguments.flag("crop")
        if arguments.flag("masks") {
            session.selectedLocalID = session.adjustments.locals.first?.id
            session.tool = .local
        }
        if arguments.flag("spots") { session.tool = .spots }
        if arguments.flag("zoom") { session.toggleZoom(at: CGPoint(x: 0.5, y: 0.5)) }
        if arguments.flag("history") {
            // A few steps to look at, for a script that checks the history list.
            session.commitEdit()
            session.adjustments.exposure = 0.35
            session.commitEdit()
            session.turn(clockwise: true)
            session.turn(clockwise: false)
            session.undo()
            session.showsHistory = true
        }
    }
}

/// Run from SwiftPM, the executable has no bundle: without this it starts as a background
/// process, with no Dock icon and no key window.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the window is up: what quitting needs to save and to send.
    @MainActor var app: AppSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A render gone wrong must cost the app, not the computer.
        MemoryFuse.arm()
        // Before the window lays out: a view measured before this is a view a script cannot
        // find, which would look exactly like a gesture that does not work.
        GestureScript.prepare()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting is the last chance to send the work of a whole session: the edits are written
    /// first, then one backup pass goes out, bounded so that it cannot hold the app open.
    /// What it does not manage to send, the next launch does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app, let backup = app.backup, backup.isConfigured, backup.isEnabled else { return .terminateNow }
        app.develop.flush()
        Task { @MainActor in
            await backup.runBeforeQuitting()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
