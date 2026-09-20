import Catalog
import Foundation
import Observation
import RawEngine

/// The whole app: a library, a develop view, and which of the two is on screen.
@MainActor
@Observable
public final class AppSession {
    public enum Mode: Sendable {
        case library, develop
    }

    public private(set) var mode = Mode.library { didSet { updateThumbnailWork() } }
    /// The strip of the rest of the shoot, under the picture being developed. Hidden, the
    /// GPU goes back to the one photo on screen.
    public var showsFilmstrip = true { didSet { updateThumbnailWork() } }
    public let library: LibrarySession
    public let develop: DevelopSession
    /// `nil` in tests: the real one reads the Keychain.
    public let backup: BackupSession?
    /// Decoded thumbnails. They belong to the app, not to the grid, so that coming back from
    /// the develop view does not start the grid from a blank.
    let thumbnails: ThumbnailLoader
    /// The large picture of the library's loupe.
    let loupe: LoupeLoader
    /// The two pictures shown side by side, each read the way the loupe reads its own.
    let comparison: (left: LoupeLoader, right: LoupeLoader)
    /// The library photo open in the develop view; `nil` for a file from outside the library.
    public private(set) var openPhotoID: Int64?

    public init(library: Library, librarySession: LibrarySession? = nil, backup: BackupSession? = nil) {
        self.backup = backup
        thumbnails = ThumbnailLoader(library: library)
        loupe = LoupeLoader(library: library)
        comparison = (LoupeLoader(library: library), LoupeLoader(library: library))
        // A crash in the middle of an import leaves half-copied originals behind, and nothing
        // ever reads them again. Swept here, before any import of this run starts.
        _ = try? Importer.sweepInterruptedImports(in: library)
        self.library = librarySession ?? LibrarySession(library: library)
        // Library photos keep their edits in the catalog; any other file, in the app's own
        // folder, under a fingerprint — a sandbox gives no right to write beside a photograph
        // that was merely opened.
        develop = DevelopSession(
            sidecars: CatalogAdjustmentsStore(library: library, fallback: SidecarStore.applicationSupport),
            versions: CatalogVersionStore(library: library),
            history: LibraryHistoryStore(library: library)
        )
    }

    /// What the filmstrip shows: the grid as it stands, while a library photo is open. A
    /// file from outside the library has no shoot around it, and no strip.
    public var filmstripPhotos: [Photo] {
        mode == .develop && openPhotoID != nil ? library.photos : []
    }

    /// Thumbnails are decoded for the grid, and for the filmstrip while it is on screen.
    /// Nothing else: during an edit the GPU belongs to the picture.
    private func updateThumbnailWork() {
        thumbnails.isSuspended = mode == .develop && (!showsFilmstrip || openPhotoID == nil)
    }

    /// Opens a photo of the grid in the develop view.
    public func open(_ photo: Photo) {
        guard develop.open(library.library.url(for: photo)) else { return }
        // What the catalog says about it goes with it, so that exporting from the develop
        // view writes the same file as exporting from the grid.
        develop.credits = (try? library.library.catalog.credits(for: photo.id)) ?? PhotoCredits()
        openPhotoID = photo.id
        library.select(photo.id)
        library.closeLoupe()
        mode = .develop
        updateThumbnailWork()
    }

    /// Opens any RAW file, whether the library knows it or not.
    public func openFile(_ url: URL) {
        guard develop.open(url) else { return }
        develop.credits = PhotoCredits()
        openPhotoID = nil
        mode = .develop
        updateThumbnailWork()
    }

    /// Back to the grid, with the edits saved and the grid up to date.
    public func showLibrary() {
        develop.flush()
        library.refresh(after: openPhotoID)
        mode = .library
        backUpSoon()
    }

    /// Imports folders and files, from the import panel or dropped on the window, with the
    /// look chosen for imports; then backs them up.
    public func importItems(_ items: [URL]) async {
        _ = await library.importItems(items, preset: library.importPreset(looks: develop.presets))
        backUpSoon()
    }

    /// Edits and imports are backed up without being asked, in the background. The backup
    /// session decides when: it merges requests and spaces runs out.
    public func backUpSoon() {
        backup?.backUpSoon()
    }

    /// Where export panels open: inside the library, so that exports are backed up with it.
    /// `nil` if the folder cannot be made: the panel then opens wherever it last was.
    public var exportsFolder: URL? {
        try? library.library.preparedExportsFolder()
    }

    // MARK: - Commands

    /// Carries out what a key, a menu or a button asked for. In the develop view, culling
    /// commands apply to the open photo; in the grid, to the selection.
    public func perform(_ command: AppCommand) {
        switch command {
        case .setTool(let tool): develop.tool = tool
        case .cancelTool: develop.cancelTool()
        case .toggleOriginal: develop.showsOriginal.toggle()
        case .toggleZoom: develop.toggleZoom(at: CGPoint(x: 0.5, y: 0.5))
        case .toggleClipping: develop.showsClipping.toggle()
        case .toggleMaskOverlay: develop.keepsMaskOverlay.toggle()
        case .turnCropAspect: develop.turnCropAspect()
        case .showLibrary: showLibrary()
        case .rate(let rating, let advance): cull(advance: advance) { library.setRating(rating) }
        case .flag(let flag, let advance): cull(advance: advance) { library.setFlag(flag) }
        case .label(let label): cull(advance: false) { library.setColorLabel(label) }
        case .moveSelection(let direction): library.move(direction)
        case .openSelection: if let photo = library.loupePhoto ?? library.selectedPhotos.first { open(photo) }
        case .selectAll: library.selectAll()
        case .toggleLoupe: library.toggleLoupe()
        case .closeLoupe:
            library.closeLoupe()
            library.stopComparing()
        case .toggleComparing: library.toggleComparing()
        }
    }

    private func cull(advance: Bool, _ change: () -> Void) {
        if mode == .develop {
            guard let openPhotoID else { return }
            library.select(openPhotoID)
        }
        change()
        guard advance else { return }
        if mode == .develop { step(by: 1) } else { library.moveSelection(by: 1) }
    }

    // MARK: - Settings across photos

    /// Settings copied in the develop view can be pasted on a whole selection of the grid.
    public var canPasteSettingsToSelection: Bool {
        develop.copiedSettings != nil && !library.selection.isEmpty
    }

    /// Copies the settings of a photo of the grid, without a trip to the develop view.
    public func copySettings(from photo: Photo) {
        develop.copySettings(of: photo.adjustments, groups: AdjustmentGroup.defaultSelection)
        library.say("Settings copied.")
    }

    public func pasteSettingsToSelection() {
        guard let copied = develop.copiedSettings else { return }
        library.apply(copied)
    }

    // MARK: - Stepping through the grid

    public func canStep(by offset: Int) -> Bool {
        neighbour(at: offset) != nil
    }

    /// The next or previous photo of the grid, without going back to it.
    public func step(by offset: Int) {
        guard let photo = neighbour(at: offset) else { return }
        open(photo)
    }

    private func neighbour(at offset: Int) -> Photo? {
        guard let openPhotoID, let index = library.photos.firstIndex(where: { $0.id == openPhotoID }) else { return nil }
        let target = index + offset
        return library.photos.indices.contains(target) ? library.photos[target] : nil
    }
}
