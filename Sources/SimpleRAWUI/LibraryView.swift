import AppKit
import Catalog
import RawEngine
import SwiftUI

/// The library: sources on the left, a grid of thumbnails, a filter bar on top of it.
struct LibraryView: View {
    @Bindable var app: AppSession
    @AppStorage("library.thumbnailSize") private var thumbnailSize: Double = 180
    @State private var albumPrompt: AlbumPrompt?
    @State private var isDropTargeted = false

    private var session: LibrarySession { app.library }

    var body: some View {
        @Bindable var session = app.library
        NavigationSplitView {
            LibrarySidebar(session: session, albumPrompt: $albumPrompt)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                // An empty library has nothing to search or to filter.
                if session.totalCount > 0 {
                    FilterBar(session: session, thumbnailSize: $thumbnailSize)
                    Divider()
                }
                if session.totalCount == 0 {
                    LibraryEmptyState(
                        isDropTargeted: isDropTargeted, importPhotos: presentImportPanel, openPhoto: { DevelopPanels.open(app.openFile) }
                    )
                } else {
                    LibraryGrid(app: app, thumbnailSize: thumbnailSize, albumPrompt: $albumPrompt)
                        .overlay {
                            // Over a library that has photos, a drop only needs to be acknowledged.
                            if isDropTargeted {
                                RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.accent, lineWidth: 2).padding(6)
                            }
                        }
                }
                if session.totalCount > 0 {
                    Divider()
                    SelectionBar(session: session)
                }
            }
            .background(Theme.canvas)
        }
        // A folder, a memory card or files dropped anywhere on the library are imported.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !session.isImporting else { return false }
            Task { await app.importItems(files) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        // Over everything, sidebar included: in the loupe there is the photo and nothing else.
        .overlay {
            if let photo = session.loupePhoto {
                LibraryLoupe(app: app, photo: photo).transition(.opacity)
            } else if session.isComparing {
                ComparisonView(app: app, photos: session.comparedPhotos).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: session.isLoupeOpen)
        .animation(.easeOut(duration: 0.12), value: session.isComparing)
        // `-loupe YES`: to look at the loupe from a script, like `-crop YES` for the crop tool.
        .onAppear { if LaunchArguments().flag("loupe") { session.openLoupe() } }
        .tint(Theme.accent)
        .toolbar {
            if let backup = app.backup, backup.isConfigured {
                ToolbarItem {
                    SettingsLink {
                        Image(systemName: BackupStatusLabel(status: backup.status).icon)
                    }
                    .help(BackupStatusLabel(status: backup.status).text)
                }
            }
            ToolbarItem {
                Button("Import", systemImage: "square.and.arrow.down", action: presentImportPanel)
                    .help("Import a folder or a memory card (⇧⌘I)")
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        .overlay { importOverlay }
        .overlay { NoticeView(text: session.notice, dismiss: session.dismissNotice) }
        .alert(session.errorTitle, isPresented: Binding(isPresent: session.errorMessage, onDismiss: session.dismissError)) {
            Button("OK", action: session.dismissError)
        } message: {
            Text(session.errorMessage ?? "")
        }
        .confirmationDialog(
            session.removalRequest?.title ?? "", isPresented: Binding(isPresent: session.removalRequest, onDismiss: session.cancelRemoval)
        ) {
            Button("Remove and Move Originals to Trash", role: .destructive, action: session.confirmRemoval)
        } message: {
            Text("Their edits are lost. The original files go to the Trash, where you can still recover them.")
        }
        .alert(albumPrompt?.album == nil ? "New Album" : "Rename Album", isPresented: Binding(isPresent: $albumPrompt), presenting: albumPrompt) { prompt in
            TextField("Name", text: Binding(get: { albumPrompt?.name ?? "" }, set: { albumPrompt?.name = $0 }))
            if let album = prompt.album {
                Button("Rename") { session.renameAlbum(album.id, to: albumPrompt?.name ?? "") }
            } else {
                Button("Create") { session.createAlbum(named: albumPrompt?.name ?? "", fromSelection: !session.selection.isEmpty) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            if prompt.album == nil {
                Text(session.selection.isEmpty ? "An empty album." : "With the \(Count.of(session.selection.count, "selected photo")).")
            }
        }
    }

    // MARK: - Import

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder or a memory card. Originals are copied into your library."
        panel.prompt = "Import"
        let looks = app.develop.presets
        panel.accessoryView = NSHostingView(rootView: ImportOptionsView(session: session, looks: looks))
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await app.importItems([folder]) }
    }

    @ViewBuilder
    private var importOverlay: some View {
        if let progress = session.exportProgress {
            ProgressOverlay(title: "Exporting \(min(progress.done + 1, progress.total)) of \(progress.total)", done: progress.done, total: progress.total, onCancel: session.cancelExport)
        } else if let progress = session.autoToneProgress {
            ProgressOverlay(
                title: "Auto: analysing \(min(progress.done + 1, progress.total)) of \(progress.total)",
                done: progress.done, total: progress.total, onCancel: session.cancelAutoTone
            )
        } else if let progress = session.importProgress {
            ProgressOverlay(
                title: progress.total == 0 ? "Looking for photos…" : "Importing \(progress.done + 1) of \(progress.total) — \(progress.currentFile)",
                done: progress.done, total: progress.total, onCancel: session.cancelImport
            )
        }
    }
}

/// What an import does to the photos it brings in, shown in the import panel.
private struct ImportOptionsView: View {
    @Bindable var session: LibrarySession
    let looks: [Preset]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Apply a look on import:", selection: $session.importLookName) {
                    Text("None — as shot").tag(String?.none)
                    Divider()
                    ForEach(looks) { Text($0.name).tag(String?.some($0.name)) }
                }
                .fixedSize()
                Text("“Camera match” starts from your camera's own rendering.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Author", text: $session.importAuthor).frame(width: 160)
                TextField("Copyright", text: $session.importCopyright).frame(width: 200)
                Text("Written on every photo that comes in, and into the files you export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}
