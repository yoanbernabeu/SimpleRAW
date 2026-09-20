import AppKit
import Catalog
import RawEngine
import SwiftUI

/// The thumbnails of what the library shows, and what can be done to them.
struct LibraryGrid: View {
    @Bindable var app: AppSession
    let thumbnailSize: Double
    @Binding var albumPrompt: AlbumPrompt?
    @FocusState private var gridIsFocused: Bool
    @Environment(\.displayScale) private var displayScale

    private var session: LibrarySession { app.library }
    private var loader: ThumbnailLoader { app.thumbnails }

    var body: some View { grid }

    private var pixelSize: Int { ThumbnailLoader.pixelSize(forCellWidth: thumbnailSize, displayScale: displayScale) }

    @ViewBuilder
    private var grid: some View {
        if session.photos.isEmpty {
            ContentUnavailableView("No photo matches", systemImage: "line.3.horizontal.decrease.circle", description: Text("Loosen the filter to see more."))
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(thumbnailSize), maximum: CGFloat(thumbnailSize) * 1.4), spacing: GridLayout.spacing)], spacing: GridLayout.spacing) {
                    ForEach(session.photos) { photo in
                        ThumbnailCell(photo: photo, slot: loader.slot(for: photo), isSelected: session.selection.contains(photo.id))
                            .equatable()
                            .id(photo.id)
                            // The cell asks when it shows up and gives its turn up when it leaves.
                            .onAppear { loader.request(photo) }
                            .onChange(of: ThumbnailLoader.key(for: photo)) { loader.request(photo) }
                            .onChange(of: pixelSize) { loader.request(photo) }
                            .onDisappear { loader.cancel(photo.id) }
                            .contextMenu { cellMenu(for: photo) }
                            .draggable(PhotoDrag.text(for: session.draggedPhotos(from: photo.id)))
                            .onTapGesture {
                                // A single gesture: stacking a double-tap on top makes every
                                // click wait a quarter of a second for a second one.
                                if NSApp.currentEvent?.clickCount == 2 { return app.open(photo) }
                                let modifiers = NSEvent.modifierFlags
                                session.select(photo.id, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
                                gridIsFocused = true
                            }
                    }
                }
                .padding(GridLayout.padding)
                .background(GeometryReader { geometry in
                    // The size of the cells changes the length of a row as much as the width does.
                    Color.clear.onChange(of: GridLayout.columns(width: geometry.size.width, cellWidth: thumbnailSize), initial: true) { _, columns in
                        session.gridColumns = columns
                    }
                })
            }
            .focusable()
            .focused($gridIsFocused)
            .focusEffectDisabled()
            .onChange(of: pixelSize, initial: true) { loader.pixelSize = pixelSize }
            .onAppear {
                gridIsFocused = true
                // Coming back from the develop view: the grid is found on the photo that was open.
                if let selected = session.selection.first { proxy.scrollTo(selected, anchor: .center) }
            }
            .onChange(of: session.selection) { _, selection in
                if selection.count == 1, let id = selection.first { proxy.scrollTo(id) }
            }
            .onKeyPress(action: app.handle)
            // Back from the loupe, the keyboard is the grid's again.
            .onChange(of: session.isLoupeOpen) { _, isOpen in if !isOpen { gridIsFocused = true } }
            }
        }
    }

    /// Acts on the selection; a right-click on a photo outside of it selects that photo first.
    @ViewBuilder
    private func cellMenu(for photo: Photo) -> some View {
        let target = { if !session.selection.contains(photo.id) { session.select(photo.id) } }
        Button("Open in Develop") { app.open(photo) }
        Button("Show Large") { session.select(photo.id); session.openLoupe() }
        Divider()
        Menu("Rating") {
            ForEach((0...5).reversed(), id: \.self) { stars in
                Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) { target(); session.setRating(stars) }
            }
        }
        Menu("Flag") {
            Button("Pick") { target(); session.setFlag(.picked) }
            Button("Reject") { target(); session.setFlag(.rejected) }
            Button("Unflag") { target(); session.setFlag(.none) }
        }
        Menu("Label") {
            ForEach(ColorLabel.allCases, id: \.self) { label in
                Button {
                    target()
                    session.setColorLabel(label)
                } label: {
                    // The dot and the name: red and green must not be told apart by color alone.
                    Label { Text(label.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(label.color) }
                }
            }
            Divider()
            Button("None") { target(); session.setColorLabel(nil) }
        }
        Menu("Add to Album") {
            ForEach(session.albums) { album in
                Button(album.name) { target(); session.addSelection(toAlbum: album.id) }
            }
            Divider()
            Button("New Album…") { target(); albumPrompt = .new }
        }
        if case .album = session.source {
            Button("Remove from Album") { target(); session.removeSelectionFromCurrentAlbum() }
        }
        Divider()
        Button("Copy Settings") { app.copySettings(from: photo) }.disabled(!photo.isEdited)
        Button("Paste Settings") { target(); app.pasteSettingsToSelection() }
            .disabled(app.develop.copiedSettings == nil)
        Menu("Apply Look") {
            ForEach(app.develop.presets) { preset in
                Button(preset.name) { target(); session.apply(preset) }
            }
        }
        Menu("Export") {
            ForEach(app.develop.exportPresets) { preset in
                Button(preset.name) { target(); presentExportPanel(using: preset) }
            }
        }
        Divider()
        Button("Remove from Library…", role: .destructive) { target(); session.requestRemovalOfSelection() }
        Button("Remove Rejected Photos…", role: .destructive, action: session.requestRemovalOfRejected)
    }

    private func presentExportPanel(using preset: ExportPreset) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        // Inside the library, so that exports are backed up with it; anywhere else is a click away.
        panel.directoryURL = try? session.library.preparedExportsFolder()
        panel.message = "Export \(Count.photos(session.selection.count)) with “\(preset.name)”."
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await session.exportSelection(to: folder, using: preset) }
    }
}

/// One photo of the grid: the picture, and what was said about it. Its name only shows when
/// it is asked for, by hovering or selecting: under every photo it was noise.
struct ThumbnailCell: View, Equatable {
    let photo: Photo
    /// The only thing the cell observes: a thumbnail that arrives redraws this cell alone.
    let slot: ThumbnailSlot
    let isSelected: Bool
    @State private var isHovered = false

    nonisolated static func == (a: ThumbnailCell, b: ThumbnailCell) -> Bool {
        a.photo == b.photo && a.isSelected == b.isSelected && a.slot === b.slot
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.tileSelected : isHovered ? Theme.tileHovered : Theme.tile)
                if let image = slot.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(8)
                        .opacity(photo.flag == .rejected ? 0.35 : 1)
                        .transition(.opacity)
                } else if slot.hasFailed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .help("This photo could not be read. Its original may be missing.")
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) { flagBadge.padding(7) }
            .overlay(alignment: .topTrailing) {
                if photo.isEdited { badge("slider.horizontal.3", on: Theme.badge).padding(7) }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2.5))
            .animation(.easeOut(duration: 0.15), value: slot.image != nil)

            HStack(spacing: 5) {
                if let label = photo.colorLabel {
                    Circle().fill(label.color).frame(width: 8, height: 8)
                }
                Text(String(repeating: "★", count: photo.rating)).font(.caption).foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
                if isSelected || isHovered {
                    Text(photo.fileName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(height: 12)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PhotoCaption.accessibilityLabel(for: photo))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var flagBadge: some View {
        switch photo.flag {
        case .picked: badge("flag.fill", on: Theme.badge)
        case .rejected: badge("xmark", on: Theme.warning.opacity(0.85))
        case .none: EmptyView()
        }
    }

    private func badge(_ icon: String, on background: Color) -> some View {
        Image(systemName: icon).font(.caption2.weight(.semibold)).foregroundStyle(Theme.onBadge).frame(width: 20, height: 20).background(background, in: Circle())
    }
}
