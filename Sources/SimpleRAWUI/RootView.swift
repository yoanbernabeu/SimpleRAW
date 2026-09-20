import AppKit
import SwiftUI

/// The window: the library, or the develop view of one of its photos. What the grid needs to
/// be found as it was left lives outside of it: decoded thumbnails in `AppSession`, their
/// size in the defaults, and on the way back the grid scrolls to the photo that was open.
public struct RootView: View {
    @Bindable var app: AppSession
    @State private var keyMonitor: Any?

    public init(app: AppSession) {
        self.app = app
    }

    public var body: some View {
        Group {
            switch app.mode {
            case .library: LibraryView(app: app)
            case .develop: developView
            }
        }
        .navigationTitle(app.mode == .develop ? (app.develop.fileName ?? "SimpleRAW") : "SimpleRAW")
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private var developView: some View {
        VStack(spacing: 0) {
            DevelopView(session: app.develop, openFile: app.openFile, exportsFolder: { app.exportsFolder })
            // Under everything, the inspector included: the strip belongs to the shoot, not
            // to the picture.
            if app.showsFilmstrip, !app.filmstripPhotos.isEmpty {
                Divider()
                FilmstripView(app: app)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.showsFilmstrip)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Library", systemImage: "square.grid.2x2", action: app.showLibrary)
                        .help("Back to the library (G)")
                    Button("Previous", systemImage: "chevron.left") { app.step(by: -1) }
                        .keyboardShortcut(.leftArrow, modifiers: [.command])
                        .disabled(!app.canStep(by: -1))
                        .help("Previous photo (⌘←)")
                    Button("Next", systemImage: "chevron.right") { app.step(by: 1) }
                        .keyboardShortcut(.rightArrow, modifiers: [.command])
                        .disabled(!app.canStep(by: 1))
                        .help("Next photo (⌘→)")
                }
            }
    }

    /// Single keys go through `KeyRouter`, which steps aside while text is being typed. A key
    /// that is a command is consumed; every other one is left to the system.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty,
                  let characters = event.charactersIgnoringModifiers else { return event }
            let key = KeyRouter.Key(characters: characters, isShiftDown: modifiers.contains(.shift))
            let handled: Bool = MainActor.assumeIsolated {
                guard let command = KeyRouter.command(for: key, mode: app.mode, tool: app.develop.tool, isTypingText: KeyRouter.isTypingText) else { return false }
                app.perform(command)
                return true
            }
            return handled ? nil : event
        }
    }
}
