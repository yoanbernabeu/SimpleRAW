import Catalog
import RawEngine
import SwiftUI

/// The menu bar. On a Mac it is where shortcuts are looked up, so everything the keyboard
/// can do is here. Commands follow what is on screen: in the grid they apply to the
/// selection, never to a photo left behind in the develop view.
///
/// Single keys are `KeyRouter`'s, which steps aside while text is typed; a menu key
/// equivalent without a modifier would not. They are written in the titles instead.
public struct AppCommands: Commands {
    let app: AppSession
    @AppStorage(DevelopView.showsInspectorKey) private var showsInspector = true

    public init(app: AppSession) {
        self.app = app
    }

    private var session: DevelopSession { app.develop }
    private var isDeveloping: Bool { app.mode == .develop && session.info != nil }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { DevelopPanels.open(app.openFile) }
                .keyboardShortcut("o")
            Divider()
            // The settings, where size, format and metadata are chosen and a preset is made;
            // the menu below exports straight away with one that already exists.
            Button("Export…") {
                if let preset = session.defaultExportPreset { session.beginExport(with: preset) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!isDeveloping || session.isExporting)
            Menu("Export With Preset") {
                ForEach(session.exportPresets) { preset in
                    Button(preset.name) { DevelopPanels.export(session, using: preset, in: app.exportsFolder) }
                }
            }
            .disabled(!isDeveloping || session.isExporting)
        }
        CommandGroup(replacing: .undoRedo) {
            // While text is being edited, undo belongs to the text.
            Button(app.mode == .library ? "Undo Change to Selection" : "Undo") {
                if KeyRouter.isTypingText {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else if app.mode == .library {
                    app.library.undoLastChange()
                } else {
                    session.undo()
                }
            }
            .keyboardShortcut("z")
            .disabled(!KeyRouter.isTypingText && !(app.mode == .library ? app.library.canUndoLastChange : isDeveloping && session.canUndo))
            Button("Redo") {
                if KeyRouter.isTypingText { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { session.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!KeyRouter.isTypingText && !(isDeveloping && session.canRedo))
            Button("History…") { session.showsHistory.toggle() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!isDeveloping)
        }
        CommandGroup(before: .toolbar) {
            Button(keyed("Library", "G")) { app.showLibrary() }.disabled(app.mode != .develop)
            Button(keyed(app.library.isLoupeOpen ? "Back to the Grid" : "Show Large", "Space")) { app.perform(.toggleLoupe) }
                .disabled(app.mode != .library || app.library.selection.isEmpty)
            Button(keyed(app.library.isComparing ? "Back to the Grid" : "Compare Two Photos", "C")) { app.perform(.toggleComparing) }
                .disabled(app.mode != .library || app.library.photos.count < 2)
            Button(keyed("Develop", "Return")) { app.perform(.openSelection) }
                .disabled(app.mode != .library || app.library.selection.isEmpty)
            Divider()
            Button(keyed(session.showsOriginal ? "Show Edited" : "Show Original", "B")) { app.perform(.toggleOriginal) }
                .disabled(!isDeveloping)
            Button(keyed(session.showsClipping ? "Hide Clipping" : "Show Clipping", "J")) { app.perform(.toggleClipping) }
                .disabled(!isDeveloping)
            Button("Zoom to Fit") { session.zoomToFit() }
                .keyboardShortcut("0")
                .disabled(!isDeveloping)
            Button("Actual Size") { session.zoomToActualSize() }
                .keyboardShortcut("1")
                .disabled(!isDeveloping || session.tool == .crop)
            Divider()
            Button(showsInspector ? "Hide Inspector" : "Show Inspector") { showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(app.mode != .develop)
            Button(app.showsFilmstrip ? "Hide Filmstrip" : "Show Filmstrip") { app.showsFilmstrip.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(app.mode != .develop)
            // A viewing condition, with the other viewing conditions: nothing of it is stored
            // with the photo, and nothing of it reaches an exported file.
            Menu("Soft Proof") {
                Button(session.softProofProfile == nil ? "✓ Screen (no proof)" : "Screen (no proof)") {
                    session.setSoftProof(nil)
                }
                Divider()
                ForEach(session.printProfiles) { profile in
                    Button(session.softProofProfile == profile ? "✓ \(profile.name)" : profile.name) {
                        session.setSoftProof(profile)
                    }
                }
                Divider()
                Button(session.softProofWarnsAboutGamut ? "✓ Mark What Will Not Print" : "Mark What Will Not Print") {
                    session.setSoftProofWarnsAboutGamut(!session.softProofWarnsAboutGamut)
                }
                .disabled(session.softProofProfile == nil)
            }
            .disabled(!isDeveloping)
            Divider()
        }
        CommandMenu("Photo") {
            let nothingToCull = app.mode == .develop ? !isDeveloping : app.library.selection.isEmpty
            Menu("Rating") {
                ForEach((0...5).reversed(), id: \.self) { stars in
                    Button(keyed(stars == 0 ? "None" : String(repeating: "★", count: stars), "\(stars)")) {
                        app.perform(.rate(stars, advance: false))
                    }
                }
            }
            .disabled(nothingToCull)
            Menu("Flag") {
                Button(keyed("Pick", "P")) { app.perform(.flag(.picked, advance: false)) }
                Button(keyed("Reject", "X")) { app.perform(.flag(.rejected, advance: false)) }
                Button(keyed("Unflag", "U")) { app.perform(.flag(.none, advance: false)) }
            }
            .disabled(nothingToCull)
            Menu("Label") {
                ForEach(ColorLabel.allCases, id: \.self) { label in
                    Button(KeyRouter.key(for: label).map { keyed(label.rawValue.capitalized, $0) } ?? label.rawValue.capitalized) { app.perform(.label(label)) }
                }
                Divider()
                Button("None") { app.perform(.label(nil)) }
            }
            .disabled(nothingToCull)
            Divider()
            Button("Remove Rejected Photos…") { app.library.requestRemovalOfRejected() }
                .disabled(app.mode != .library)
            Divider()
            Text("Hold ⇧ with a rating or a flag to move on to the next photo")
        }
        CommandMenu("Develop") {
            // In the grid, each selected photo gets its own Auto, read off its own picture:
            // the first thing a batch is ever asked for.
            Button(app.mode == .library ? "Auto on Selection" : "Auto") {
                if app.mode == .library {
                    Task { await app.library.autoToneSelection() }
                } else {
                    session.autoTone()
                }
            }
            .keyboardShortcut("u")
            .disabled(app.mode == .library ? app.library.selection.isEmpty || app.library.autoToneProgress != nil : !isDeveloping)
            Button("Reset All Adjustments") { session.reset() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!isDeveloping || !session.hasChanges)
            Divider()
            Button("Copy Settings") { session.copyAdjustments() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!isDeveloping)
            Button("Copy Settings…") { session.isChoosingCopiedGroups = true }
                .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                .disabled(!isDeveloping)
            Button(app.mode == .library ? "Paste Settings on Selection" : "Paste Settings") {
                if app.mode == .library { app.pasteSettingsToSelection() } else { session.pasteAdjustments() }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(app.mode == .library ? !app.canPasteSettingsToSelection : !session.canPaste)
            Divider()
            Menu("Apply Look") {
                ForEach(session.presets) { preset in
                    Button(preset.name) {
                        if app.mode == .library { app.library.apply(preset) } else { session.apply(preset) }
                    }
                }
            }
            .disabled(app.mode == .library ? app.library.selection.isEmpty : !isDeveloping)
        }
        CommandMenu("Tools") {
            tool(.crop, "Crop", "C")
            // Part of the crop tool: it puts it down again to the crop, never to nothing.
            Button(keyed(session.tool == .level ? "Put Down Level" : "Level", "L")) {
                app.perform(.setTool(session.tool == .level ? .crop : .level))
            }
            .disabled(!isDeveloping || !session.isCropping)
            tool(.local, "Masks", "M")
            tool(.spots, "Spot Removal", "S")
            tool(.whiteBalance, "White Balance Eyedropper", "W")
        }
    }

    private func tool(_ tool: Tool, _ title: String, _ key: String) -> some View {
        Button(keyed(session.tool == tool ? "Put Down \(title)" : title, key)) {
            app.perform(.setTool(session.tool == tool ? .none : tool))
        }
        .disabled(!isDeveloping)
    }

    /// A title that says which single key does the same.
    private func keyed(_ title: String, _ key: String) -> String {
        "\(title)    \(key)"
    }
}
