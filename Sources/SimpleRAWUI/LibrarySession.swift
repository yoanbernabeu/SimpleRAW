import Catalog
import Foundation
import Observation
import RawEngine

/// What the grid shows: the whole library, an album, or a smart album. The filter bar
/// applies on top of any of them.
public enum LibrarySource: Hashable, Sendable {
    case allPhotos
    case album(Int64)
    case smartAlbum(Int64)
    /// One month of shooting, as the sidebar lists it.
    case month(year: Int, month: Int)
}

/// State of the library window. Views read and write this; the catalog does the work.
@MainActor
@Observable
public final class LibrarySession {
    public let library: Library
    public var source = LibrarySource.allPhotos { didSet { if source != oldValue { reloadPhotos() } } }
    public var filter = PhotoFilter() { didSet { if filter != oldValue { reloadPhotos() } } }
    public var sort = PhotoSort.captureDate(ascending: false) { didSet { if sort != oldValue { reloadPhotos() } } }
    /// What the search field holds. It reaches `filter.text` once typing pauses: a query per
    /// character would be wasted, the first one matching nearly everything.
    public var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }

    public private(set) var photos: [Photo] = []
    public private(set) var selection: Set<Int64> = [] { didSet { if selection != oldValue { scheduleKeywords() } } }
    public private(set) var albums: [Album] = []
    public private(set) var smartAlbums: [SmartAlbum] = []
    public private(set) var totalCount = 0
    /// The cameras the library holds photos from, for the filter bar.
    public private(set) var cameras: [String] = []
    /// The months the library holds photos from, newest first: the sidebar's view by date.
    public private(set) var months: [PhotoCatalog.CaptureMonth] = []
    /// The keywords every selected photo has, as the keyword field shows them: "Lille, street".
    /// Read in the background, a moment after the selection settles.
    public private(set) var keywordText = ""
    /// How many times the grid was asked to be read back from the catalog, and how many times
    /// it actually was: a question that a newer one replaced is never put. For tests.
    @ObservationIgnored public private(set) var reloadCount = 0
    @ObservationIgnored public private(set) var readCount = 0
    public private(set) var errorMessage: String?
    /// What failed, in a few words: the title of the alert that shows `errorMessage`.
    public private(set) var errorTitle = "The library could not be updated"
    /// Good news, shown for a moment: an import or an export that went through.
    public private(set) var notice: String?
    public private(set) var importProgress: ImportProgress?
    /// Photos exported so far, out of how many, while an export runs.
    public private(set) var exportProgress: (done: Int, total: Int)?
    /// How far Auto has got through the selection.
    public private(set) var autoToneProgress: (done: Int, total: Int)?

    public struct ImportProgress: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var currentFile: String
    }

    /// Where a shift-click extends the selection from.
    private var anchor: Int64?
    /// Where each photo is in `photos`. Rebuilt when the grid is read, not when it is patched.
    @ObservationIgnored private var indexByID: [Int64: Int] = [:]
    /// The last question put to the catalog about the grid; an answer to an older one is dropped.
    @ObservationIgnored private var generation = 0
    /// Work on the catalog runs off the main actor, one piece after the other, in the order
    /// it was asked for. This is the last piece.
    @ObservationIgnored private var lastJob: Task<Void, Never>?
    @ObservationIgnored private var searchDebounce: Task<Void, Never>?
    @ObservationIgnored private var keywordDebounce: Task<Void, Never>?
    /// What `keywordText` was read for, and the keywords it stands for.
    @ObservationIgnored private var shownKeywords: (selection: Set<Int64>, common: Set<String>)?
    /// The photos the keyword field is being edited for.
    @ObservationIgnored private var keywordTarget: Set<Int64>?
    private static let searchDelay = Duration.milliseconds(220)
    private static let keywordDelay = Duration.milliseconds(120)
    @ObservationIgnored private let discard: @Sendable (URL) throws -> Void
    @ObservationIgnored private let metadata: @Sendable (URL) throws -> FileMetadata
    /// The import and the export that are running, kept so that they can be cancelled.
    @ObservationIgnored private let autoTone: @Sendable (URL) throws -> AutoToneResult
    @ObservationIgnored private var importTask: Task<ImportSummary, Never>?
    @ObservationIgnored private var exportTask: Task<[BatchJob.Outcome], Never>?
    @ObservationIgnored private var autoToneTask: Task<(done: [Int64: Adjustments], failures: [(URL, Error)]), Never>?
    @ObservationIgnored private let defaults: UserDefaults
    /// What the photos held before the last change made to several of them at once.
    private var lastBatch: [Int64: Adjustments]?
    /// The look applied to photos as they are imported; `nil` = as shot.
    public var importLookName: String? {
        didSet { defaults.set(importLookName, forKey: Self.importLookKey) }
    }
    private static let importLookKey = "library.importLook"
    /// Who made the photos and who owns them, written on every one that comes in. Remembered,
    /// because it is the same answer for years: a photographer signs their own work once.
    public var importAuthor: String {
        didSet { defaults.set(importAuthor, forKey: Self.importAuthorKey) }
    }
    public var importCopyright: String {
        didSet { defaults.set(importCopyright, forKey: Self.importCopyrightKey) }
    }
    private static let importAuthorKey = "library.importAuthor"
    private static let importCopyrightKey = "library.importCopyright"
    /// Whether the filter row is unfolded when nothing is filtered. Remembered.
    public var showsFilters: Bool {
        didSet { defaults.set(showsFilters, forKey: Self.showsFiltersKey) }
    }
    private static let showsFiltersKey = "library.showsFilters"

    /// A row that filters is never hidden: what narrows the grid must be in sight.
    public var isFilterRowVisible: Bool { showsFilters || filter.criteriaCount > 0 }

    /// "4 of 10", only while something narrows the grid: otherwise it repeats the sidebar.
    public var filteredCountText: String? {
        filter.isEmpty ? nil : "\(photos.count) of \(totalCount)"
    }

    /// - Parameters:
    ///   - discard: what happens to the original of a removed photo. The Trash, where it can
    ///     be recovered, unless a test says otherwise.
    ///   - metadata: how an import reads a file's metadata; the engine, unless a test says otherwise.
    ///   - autoTone: how a photo is analysed for Auto; the engine, unless a test says otherwise.
    public init(
        library: Library,
        defaults: UserDefaults = .standard,
        discard: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        metadata: @escaping @Sendable (URL) throws -> FileMetadata = FileMetadata.read(from:),
        autoTone: @escaping @Sendable (URL) throws -> AutoToneResult = { try AutoTone.settings(for: RawSource(url: $0)) }
    ) {
        self.library = library
        self.defaults = defaults
        self.discard = discard
        self.metadata = metadata
        self.autoTone = autoTone
        importLookName = defaults.string(forKey: Self.importLookKey)
        importAuthor = defaults.string(forKey: Self.importAuthorKey) ?? ""
        importCopyright = defaults.string(forKey: Self.importCopyrightKey) ?? ""
        showsFilters = defaults.bool(forKey: Self.showsFiltersKey)
        // The first grid is read before the window shows, so that it never opens on a blank.
        attempt {
            try readAlbums()
            show(try Self.read(gridRequest(countsLibrary: true), from: library.catalog))
        }
    }

    /// What an import does to incoming photos. A look that no longer exists is ignored.
    public func importPreset(looks: [Preset]) -> ImportPreset {
        var preset = ImportPreset.builtIns[0]
        preset.look = looks.first { $0.name == importLookName }
        preset.author = importAuthor
        preset.copyright = importCopyright
        return preset
    }

    // MARK: - Loading

    /// Reads everything again: the grid, the sources, the size of the library. In the
    /// background; `settle()` waits for it.
    public func reload() {
        attempt(readAlbums)
        reloadPhotos(countsLibrary: true)
    }

    /// Back from the develop view: the photo that was open shows its edits at once, and the
    /// rest of the grid, which stepping may have edited too, is read again behind.
    public func refresh(after edited: Int64?) {
        // The row as the catalog holds it: its edits stay undecoded, its fingerprint saved.
        if let edited, let index = indexByID[edited], let row = try? library.catalog.photo(edited) {
            photos[index] = row
        }
        reload()
    }

    /// Waits until everything asked so far is done and shown. Tests need it; the interface
    /// never does, it shows what it has.
    public func settle() async {
        while let task = searchDebounce ?? keywordDebounce ?? lastJob {
            await task.value
            if lastJob == task { lastJob = nil }
        }
    }

    /// What the grid shows and how. The question is put in the background and Photos the
    /// filter now hides leave the selection when the answer comes.
    private func reloadPhotos(countsLibrary: Bool = false) {
        reloadCount += 1
        generation += 1
        let (catalog, asked) = (library.catalog, generation)
        let request = gridRequest(countsLibrary: countsLibrary)
        run(unless: { [weak self] in
            guard let self, generation == asked else { return true }
            readCount += 1
            return false
        }) {
            try Self.read(request, from: catalog)
        } then: { [weak self] loaded in
            guard let self, generation == asked else { return }
            show(loaded)
        }
    }

    private struct GridRequest: Sendable {
        var filters: [PhotoFilter]
        var sort: PhotoSort
        /// Whether the size of the library and its cameras may have changed too.
        var countsLibrary: Bool
    }

    private struct Loaded: Sendable {
        var photos: [Photo]
        var library: (count: Int, cameras: [String], months: [PhotoCatalog.CaptureMonth])?
    }

    private func gridRequest(countsLibrary: Bool) -> GridRequest {
        GridRequest(filters: effectiveFilters, sort: sort, countsLibrary: countsLibrary)
    }

    private nonisolated static func read(_ request: GridRequest, from catalog: PhotoCatalog) throws -> Loaded {
        Loaded(
            photos: try catalog.photos(matching: request.filters, sort: request.sort),
            library: request.countsLibrary
                ? (try catalog.count(matching: PhotoFilter()), try catalog.cameras(), try catalog.captureMonths())
                : nil
        )
    }

    private func show(_ loaded: Loaded) {
        let loupeIndex = loupePhoto.flatMap { indexByID[$0.id] }
        photos = loaded.photos
        indexByID = Dictionary(uniqueKeysWithValues: photos.indices.map { (photos[$0].id, $0) })
        if let (count, cameras, months) = loaded.library {
            totalCount = count
            self.cameras = cameras
            self.months = months
            // A month emptied by a removal is no longer a place to stand in.
            if case .month = source, !months.contains(where: { monthSource($0) == source }) { source = .allPhotos }
        }
        let stillShown = selection.filter { indexByID[$0] != nil }
        if stillShown.count != selection.count { selection = stillShown }
        // The photo in the loupe left what the filter shows: its neighbour takes its place.
        if let compared = comparedIDs, indexByID[compared.left] == nil || indexByID[compared.right] == nil {
            stopComparing()
        }
        if isLoupeOpen, selection.isEmpty {
            if let loupeIndex, !photos.isEmpty { select(photos[min(loupeIndex, photos.count - 1)].id) } else { isLoupeOpen = false }
        }
    }

    /// Albums are few: they are read at once, and only when they may have changed.
    private func readAlbums() throws {
        albums = try library.catalog.albums()
        smartAlbums = try library.catalog.smartAlbums()
    }

    /// The source and the filter bar, combined.
    /// A photo shows if it matches every one of them.
    private var effectiveFilters: [PhotoFilter] {
        switch source {
        case .allPhotos:
            return [filter]
        case .album(let id):
            return [PhotoFilter(album: id), filter]
        case .smartAlbum(let id):
            // The saved filter is the base; what the bar adds can only narrow it. It is read
            // from memory: the sidebar already holds it.
            guard let saved = smartAlbums.first(where: { $0.id == id })?.filter else { return [filter] }
            return [saved, filter]
        case .month(let year, let month):
            guard let range = Self.monthRange(year: year, month: month) else { return [filter] }
            return [PhotoFilter(capturedFrom: range.from, capturedTo: range.to), filter]
        }
    }

    public func monthSource(_ month: PhotoCatalog.CaptureMonth) -> LibrarySource {
        .month(year: month.year, month: month.month)
    }

    /// The month as the catalog grouped it: UTC, like the folders of `Originals`.
    static func monthRange(year: Int, month: Int) -> (from: Date, to: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let from = calendar.date(from: DateComponents(year: year, month: month)),
              let to = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: from) else { return nil }
        return (from, to)
    }

    /// Runs `work` off the main actor, after what was asked before it, then `then` back on
    /// it. An error is reported like any other.
    /// - Parameter unless: asked when the turn of `work` comes; true gives it up.
    private func run<T: Sendable>(
        unless isStale: @escaping @MainActor () -> Bool = { false },
        _ work: @escaping @Sendable () async throws -> T,
        then: @escaping @MainActor (T) -> Void
    ) {
        let previous = lastJob
        lastJob = Task { [weak self] in
            await previous?.value
            guard !isStale() else { return }
            do {
                then(try await Task.detached(priority: .userInitiated, operation: work).value)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchDebounce?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard let self, !Task.isCancelled else { return }
            searchDebounce = nil
            let text = searchText.trimmingCharacters(in: .whitespaces)
            filter.text = text.isEmpty ? nil : text
        }
        searchDebounce = task
    }

    /// Shows everything the source holds again, and empties the search field with the rest.
    public func clearFilter() {
        searchDebounce?.cancel()
        searchDebounce = nil
        searchText = ""
        searchDebounce?.cancel()
        searchDebounce = nil
        filter = PhotoFilter()
    }

    // MARK: - Selection

    /// In the order of the grid. Found through the index: asking never walks the whole grid.
    public var selectedPhotos: [Photo] { selection.compactMap { indexByID[$0] }.sorted().map { photos[$0] } }

    /// A plain click selects one photo; command-click toggles it; shift-click selects the
    /// range from the last plain click.
    public func select(_ id: Int64, extending: Bool = false, toggling: Bool = false) {
        if toggling {
            selection.formSymmetricDifference([id])
            anchor = id
        } else if extending, let anchor, let from = index(of: anchor), let to = index(of: id) {
            selection = Set(photos[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    /// Arrow keys: moves a single selection along the grid, stopping at its ends.
    public func moveSelection(by offset: Int) {
        guard !photos.isEmpty else { return }
        let current = selection.count == 1 ? selection.first.flatMap(index(of:)) : anchor.flatMap(index(of:))
        let target = min(max((current ?? -1) + offset, 0), photos.count - 1)
        select(photos[current == nil ? 0 : target].id)
    }

    /// Arrow keys. In the grid, up and down go along the rows; in the loupe there are no rows,
    /// and they go to the neighbours like left and right.
    public enum MoveDirection: Sendable {
        case left, right, up, down
    }

    /// How many cells a row of the grid holds: what the grid measured.
    @ObservationIgnored public var gridColumns = 1

    public func move(_ direction: MoveDirection) {
        // Between two pictures there is nowhere to go but from one to the other.
        if let comparedIDs {
            switch direction {
            case .left: select(comparedIDs.left)
            case .right: select(comparedIDs.right)
            case .up, .down: break
            }
            return
        }
        let rowLength = isLoupeOpen ? 1 : max(gridColumns, 1)
        switch direction {
        case .left: moveSelection(by: -1)
        case .right: moveSelection(by: 1)
        case .up: moveSelection(by: -rowLength)
        case .down: moveSelection(by: rowLength)
        }
    }

    // MARK: - Comparing two photos

    /// The two photos being judged side by side, in the order of the grid. The one that is
    /// selected is the one being judged: rating, flagging and labelling need to know nothing
    /// about comparing.
    @ObservationIgnored private var comparedIDs: (left: Int64, right: Int64)? {
        didSet { withMutation(keyPath: \.comparedIDs) {} }
    }

    public var isComparing: Bool { comparedIDs != nil }

    public var comparedPhotos: [Photo] {
        guard let comparedIDs else { return [] }
        return [comparedIDs.left, comparedIDs.right].compactMap { indexByID[$0] }.map { photos[$0] }
    }

    /// Compares the two selected photos, or the selected one with the frame next to it: "is
    /// the next one better?" is the question a grid of thumbnails cannot settle.
    public func startComparing() {
        let selected = selectedPhotos
        let pair: [Photo]
        if selected.count >= 2 {
            pair = Array(selected.prefix(2))
        } else if let one = selected.first ?? photos.first, let index = indexByID[one.id] {
            // The frame after it, or the one before it at the end of the grid.
            let neighbour = [index + 1, index - 1].first { photos.indices.contains($0) }
            guard let neighbour else { return }
            pair = (neighbour > index ? [one, photos[neighbour]] : [photos[neighbour], one])
        } else {
            return
        }
        comparedIDs = (pair[0].id, pair[1].id)
        // The photo that was asked for stays the one being judged.
        select(selected.first?.id ?? pair[0].id)
        isLoupeOpen = false
    }

    public func stopComparing() { comparedIDs = nil }

    public func toggleComparing() {
        if isComparing { stopComparing() } else { startComparing() }
    }

    // MARK: - Loupe

    /// Whether the selected photo is shown as large as the window, to cull on what it really
    /// looks like. Rating, flagging and labelling work as in the grid.
    public private(set) var isLoupeOpen = false

    public var loupePhoto: Photo? { isLoupeOpen ? selectedPhotos.first : nil }

    /// "3 of 13": where the loupe is in what the grid shows.
    public var loupePosition: String? {
        loupePhoto.flatMap { indexByID[$0.id] }.map { "\($0 + 1) of \(photos.count)" }
    }

    /// The photo after the one in the loupe: read ahead, since a cull goes forward.
    public var photoAfterLoupe: Photo? {
        guard let index = loupePhoto.flatMap({ indexByID[$0.id] }), photos.indices.contains(index + 1) else { return nil }
        return photos[index + 1]
    }

    /// One photo is on screen: a selection of several comes down to the one last clicked, and
    /// with nothing selected the loupe starts on the first photo.
    public func openLoupe() {
        guard let shown = anchor.flatMap({ selection.contains($0) ? $0 : nil }) ?? selectedPhotos.first?.id ?? photos.first?.id else { return }
        select(shown)
        stopComparing()
        isLoupeOpen = true
    }

    public func closeLoupe() { isLoupeOpen = false }

    public func toggleLoupe() {
        if isLoupeOpen { closeLoupe() } else { openLoupe() }
    }

    public func selectAll() { selection = Set(photos.map(\.id)) }
    public func deselectAll() { selection = [] }

    private func index(of id: Int64) -> Int? { indexByID[id] }

    // MARK: - Rating, flags, labels, keywords

    public func setRating(_ rating: Int) {
        let clamped = min(max(rating, 0), 5)
        update(movesPhotos: filter.minimumRating > 0 || sort == .rating, { $0.rating = clamped }) {
            try library.catalog.setRating(clamped, for: $0)
        }
    }

    public func setFlag(_ flag: Flag) {
        update(movesPhotos: filter.flags != nil, { $0.flag = flag }) { try library.catalog.setFlag(flag, for: $0) }
    }

    /// Choosing the label a selection already has clears it, like a toggle.
    /// Setting the label the whole selection already has takes it off; `nil` always does.
    public func setColorLabel(_ label: ColorLabel?) {
        let alreadySet = !selectedPhotos.isEmpty && selectedPhotos.allSatisfy { $0.colorLabel == label }
        let applied = alreadySet ? nil : label
        update(movesPhotos: filter.colorLabels != nil, { $0.colorLabel = applied }) {
            try library.catalog.setColorLabel(applied, for: $0)
        }
    }

    /// Writes a change to the catalog and shows it. The grid is patched in place, which is
    /// instant whatever the size of the library; it is only read back when the change can
    /// move a photo in or out of what the filter shows, or along the sort order.
    private func update(movesPhotos: Bool, _ patch: (inout Photo) -> Void, write: ([Int64]) throws -> Void) {
        guard !selection.isEmpty else { return }
        var succeeded = false
        attempt {
            try write(Array(selection))
            succeeded = true
        }
        guard succeeded, !movesPhotos else { return reloadPhotos() }
        for index in photos.indices where selection.contains(photos[index].id) {
            patch(&photos[index])
        }
    }

    // MARK: - Credits

    /// What the selection says about itself, as the fields show it: a value the selected
    /// photos share, and nothing where they differ. Read off the rows of the grid, which
    /// carry it already — unlike the keywords, which live in tables of their own.
    public var shownCredits: PhotoCredits {
        let selected = selectedPhotos
        guard let first = selected.first?.credits else { return PhotoCredits() }
        func shared(_ field: KeyPath<PhotoCredits, String?>) -> String? {
            selected.allSatisfy { $0.credits[keyPath: field] == first[keyPath: field] } ? first[keyPath: field] : nil
        }
        return PhotoCredits(title: shared(\.title), caption: shared(\.caption), author: shared(\.author), copyright: shared(\.copyright))
    }

    /// Writes the four fields onto every selected photo. A title names one picture, so the
    /// panel only offers it for a single photo; an author is offered for a whole shoot, and
    /// goes through `setSignature`, which leaves each title alone.
    public func setCredits(_ credits: PhotoCredits) {
        update(movesPhotos: searchesText, { $0.credits = credits }) { try library.catalog.setCredits(credits, for: $0) }
    }

    /// Signs the selection: who made the pictures and who owns them, nothing else.
    public func setSignature(author: String?, copyright: String?) {
        let (author, copyright) = (PhotoCredits.nonBlank(author), PhotoCredits.nonBlank(copyright))
        update(movesPhotos: false, { $0.credits.author = author; $0.credits.copyright = copyright }) {
            try library.catalog.setSignature(author: author, copyright: copyright, for: $0)
        }
    }

    /// A title or a caption can be what puts a photo in the grid: changing one moves photos
    /// exactly when the grid is showing the result of a search.
    private var searchesText: Bool {
        effectiveFilters.contains { $0.text != nil }
    }

    // MARK: - Keywords

    /// Throws rather than answering "none": an error must never read as an empty list, which
    /// the next change would then write back.
    public func keywords(for id: Int64) throws -> [String] {
        try library.catalog.keywords(for: id)
    }

    /// What the keyword field holds: "street, Lille". The field shows what the selection
    /// shares, so submitting it is a difference against that: what was added goes to every
    /// selected photo, what was removed leaves them all, and the keywords a photo has of its
    /// own are never touched. One transaction for the whole selection, off the main actor.
    public func setKeywords(fromText text: String) {
        setKeywords(fromText: text, for: selection)
    }

    /// The keyword field has the keyboard: what it holds is for the photos selected now, even
    /// if it is left by clicking another one.
    public func beginEditingKeywords() { keywordTarget = selection }

    /// Return commits and keeps editing; nothing is committed once editing has ended, when the
    /// field may still hold the text of photos that are no longer the selected ones.
    public func commitKeywords(_ text: String) {
        guard let keywordTarget else { return }
        setKeywords(fromText: text, for: keywordTarget)
    }

    public func endEditingKeywords(_ text: String) {
        commitKeywords(text)
        keywordTarget = nil
    }

    private func setKeywords(fromText text: String, for ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        let typed = Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let catalog = library.catalog
        // What the field showed, if it was read for this very selection; read now otherwise.
        let known = shownKeywords.flatMap { $0.selection == ids ? $0.common : nil }
        run {
            let shown = try known ?? Set(catalog.commonKeywords(of: Array(ids)))
            let (added, removed) = (typed.subtracting(shown), shown.subtracting(typed))
            guard !added.isEmpty || !removed.isEmpty else { return false }
            // One transaction for the whole selection: all of it, or none of it.
            try catalog.database.transaction {
                try catalog.removeKeywords(Array(removed), from: Array(ids))
                try catalog.addKeywords(Array(added), to: Array(ids))
            }
            return true
        } then: { [weak self] changed in
            guard let self, changed else { return }
            if selection == ids { readKeywords() }
            // The grid only depends on keywords through the search and the keyword filter.
            if effectiveFilters.contains(where: { $0.text != nil || !$0.keywords.isEmpty }) { reloadPhotos() }
        }
    }

    /// Selecting never waits for keywords: they are read a moment after the selection settles.
    private func scheduleKeywords() {
        keywordDebounce?.cancel()
        keywordDebounce = nil
        guard !selection.isEmpty else {
            shownKeywords = ([], [])
            keywordText = ""
            return
        }
        keywordDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.keywordDelay)
            guard let self, !Task.isCancelled else { return }
            keywordDebounce = nil
            readKeywords()
        }
    }

    private func readKeywords() {
        let (ids, catalog) = (selection, library.catalog)
        run(unless: { [weak self] in self?.selection != ids }) {
            // A query per few hundred photos, not one per photo.
            try catalog.commonKeywords(of: Array(ids))
        } then: { [weak self] common in
            guard let self, selection == ids else { return }
            shownKeywords = (ids, Set(common))
            keywordText = common.joined(separator: ", ")
        }
    }

    // MARK: - Albums

    public func createAlbum(named name: String, fromSelection: Bool = false) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        attempt {
            let id = try library.catalog.createAlbum(named: name)
            if fromSelection { try library.catalog.add(Array(selection), toAlbum: id) }
            try readAlbums()
        }
    }

    public func addSelection(toAlbum id: Int64) {
        add(Array(selection), toAlbum: id)
    }

    /// What a drop on an album of the sidebar does.
    public func add(_ ids: [Int64], toAlbum id: Int64) {
        guard !ids.isEmpty, let album = albums.first(where: { $0.id == id }) else { return }
        attempt {
            try library.catalog.add(ids, toAlbum: id)
            notice = "\(Count.photos(ids.count)) added to “\(album.name)”."
        }
        if source == .album(id) { reloadPhotos() }
    }

    /// Dragging a thumbnail of the selection drags the whole selection, in the order of the
    /// grid; any other thumbnail goes alone.
    public func draggedPhotos(from id: Int64) -> [Int64] {
        selection.contains(id) ? selectedPhotos.map(\.id) : [id]
    }

    /// An empty name is no name: the album keeps its own.
    public func renameAlbum(_ id: Int64, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        attempt {
            try library.catalog.renameAlbum(id, to: name)
            try readAlbums()
        }
    }

    public func removeSelectionFromCurrentAlbum() {
        guard case .album(let id) = source else { return }
        attempt { try library.catalog.remove(Array(selection), fromAlbum: id) }
        reloadPhotos()
    }

    public func saveFilterAsSmartAlbum(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !filter.isEmpty else { return }
        attempt {
            try library.catalog.createSmartAlbum(named: name, filter: filter)
            try readAlbums()
        }
    }

    public func deleteAlbum(_ id: Int64) {
        attempt {
            try library.catalog.deleteAlbum(id)
            try readAlbums()
        }
        if source == .album(id) || source == .smartAlbum(id) { source = .allPhotos }
    }

    // MARK: - Settings across photos

    /// Applies a look to every selected photo: the groups it carries replace theirs.
    public func apply(_ preset: Preset) {
        let selected = selectedPhotos
        guard !selected.isEmpty else { return }
        lastBatch = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.adjustments) })
        let catalog = library.catalog
        // One transaction for the whole selection, not one write to disk per photo.
        run {
            try catalog.setAdjustments(Dictionary(uniqueKeysWithValues: selected.map { photo in
                var adjustments = photo.adjustments
                preset.apply(to: &adjustments)
                return (photo.id, adjustments)
            }))
        } then: { [weak self] in
            self?.reloadPhotos()
        }
    }

    /// Auto on a selection: the everyday use of a batch. Unlike a look, there is no one
    /// answer to copy across — each photo needs its own, read off its own picture — so it is
    /// a background job with progress, one photo at a time, and it can be stopped.
    /// What it did keeps; the light and vibrance are replaced, the rest of the edits stay.
    public func autoToneSelection() async {
        let selected = selectedPhotos
        guard !selected.isEmpty, autoToneProgress == nil else { return }
        let files = selected.map { (id: $0.id, url: library.url(for: $0), adjustments: $0.adjustments) }
        let analyze = autoTone
        autoToneProgress = (0, files.count)

        let (steps, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached(priority: .userInitiated) { () -> (done: [Int64: Adjustments], failures: [(URL, Error)]) in
            defer { continuation.finish() }
            var done: [Int64: Adjustments] = [:]
            var failures: [(URL, Error)] = []
            // One photo at a time, so that a cancellation is heard between two of them.
            for file in files where !Task.isCancelled {
                do {
                    var adjustments = file.adjustments
                    try analyze(file.url).apply(to: &adjustments)
                    done[file.id] = adjustments
                } catch {
                    failures.append((file.url, error))
                }
                continuation.yield(done.count + failures.count)
            }
            return (done, failures)
        }
        autoToneTask = task
        for await step in steps { autoToneProgress = (step, files.count) }
        let (done, failures) = await task.value
        let wasCancelled = task.isCancelled
        autoToneTask = nil
        autoToneProgress = nil

        if !done.isEmpty {
            // What each photo held before, so that the whole batch is one undo.
            lastBatch = Dictionary(uniqueKeysWithValues: selected.filter { done[$0.id] != nil }.map { ($0.id, $0.adjustments) })
            let catalog = library.catalog
            run {
                try catalog.setAdjustments(done)
            } then: { [weak self] in
                self?.reloadPhotos()
            }
        }
        if let failure = failures.first {
            fail("Auto could not analyse some photos", "\(Count.photos(failures.count)) failed. \(failure.0.lastPathComponent): \(failure.1.localizedDescription)")
        }
        if wasCancelled {
            notice = "Auto cancelled." + (done.isEmpty ? "" : " \(Count.photos(done.count)) done.")
        } else if !done.isEmpty {
            notice = "Auto applied to \(Count.photos(done.count))."
        }
    }

    /// Stops after the photo being analysed; what was done stays.
    public func cancelAutoTone() { autoToneTask?.cancel() }

    public var canUndoLastChange: Bool { lastBatch != nil }

    /// Gives every photo of the last batch change back what it held before it.
    public func undoLastChange() {
        guard let batch = lastBatch else { return }
        lastBatch = nil
        let catalog = library.catalog
        run {
            try catalog.setAdjustments(batch)
        } then: { [weak self] in
            self?.reloadPhotos()
        }
    }

    // MARK: - Export and removal

    /// Develops every selected photo with its own edits, off the main actor. Progress comes
    /// back through a stream that this very function reads: it is in order, and over when the
    /// function returns, so nothing can light the overlay again afterwards.
    public func exportSelection(to directory: URL, using preset: ExportPreset) async -> [BatchJob.Outcome] {
        let selected = selectedPhotos
        let files = selected.map(library.url(for:))
        guard !files.isEmpty, exportProgress == nil else { return [] }
        // Read here, once, rather than from the catalog while files are being written: what
        // the photos say about themselves now goes into the files that leave.
        let credits = Dictionary(uniqueKeysWithValues: selected.map {
            (library.url(for: $0), (try? library.catalog.credits(for: $0.id)) ?? PhotoCredits())
        })
        let job = BatchJob(
            preset: nil, exportPreset: preset, outputDirectory: directory,
            sidecars: CatalogAdjustmentsStore(library: library, fallback: nil),
            credits: { credits[$0] ?? PhotoCredits() }
        )
        exportProgress = (0, files.count)
        let (steps, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            var outcomes: [BatchJob.Outcome] = []
            // One file at a time, so that a cancellation is heard between two of them.
            for file in files where !Task.isCancelled {
                outcomes += job.run(on: [file])
                continuation.yield(outcomes.count)
            }
            return outcomes
        }
        exportTask = task
        for await done in steps { exportProgress = (done, files.count) }
        let outcomes = await task.value
        let wasCancelled = task.isCancelled
        exportTask = nil
        exportProgress = nil

        let failures = outcomes.filter { !$0.isSuccess }
        if let failure = failures.first {
            fail("Some photos could not be exported", "\(Count.photos(failures.count)) failed. \(failure.source.lastPathComponent): \(failure.error?.localizedDescription ?? "")")
        }
        let exported = outcomes.count - failures.count
        if wasCancelled {
            notice = "Export cancelled." + (exported > 0 ? " \(Count.photos(exported)) exported to “\(directory.lastPathComponent)”." : "")
        } else if exported > 0 {
            notice = "\(Count.photos(exported)) exported to “\(directory.lastPathComponent)”."
        }
        return outcomes
    }

    /// Stops after the photo being exported; what was exported stays.
    public func cancelExport() { exportTask?.cancel() }

    /// Takes the selected photos out of the library and discards their originals: to the
    /// Trash, where they can be recovered. Nothing is deleted for good.
    public func removeSelectionFromLibrary() {
        remove(selectedPhotos)
    }

    /// Photos about to leave the library, waiting for the user to confirm.
    public struct RemovalRequest: Equatable, Sendable {
        public let photos: [Photo]
        public let title: String
    }

    public private(set) var removalRequest: RemovalRequest?

    public func requestRemovalOfSelection() {
        let photos = selectedPhotos
        guard !photos.isEmpty else { return }
        removalRequest = RemovalRequest(photos: photos, title: "Remove \(Count.photos(photos.count)) from the library?")
    }

    /// The end of a cull, in one command: every rejected photo of the source, whatever the
    /// filter bar shows of it.
    public func requestRemovalOfRejected() {
        // The last filter is the bar's: the rejected photos take its place.
        let filters = effectiveFilters.dropLast() + [PhotoFilter(flags: [.rejected])]
        let catalog = library.catalog
        run {
            try catalog.photos(matching: Array(filters))
        } then: { [weak self] rejected in
            guard let self else { return }
            guard !rejected.isEmpty else { return notice = "No photo is rejected here." }
            removalRequest = RemovalRequest(
                photos: rejected, title: "Remove \(Count.of(rejected.count, "rejected photo")) from the library?"
            )
        }
    }

    public func confirmRemoval() {
        guard let request = removalRequest else { return }
        removalRequest = nil
        remove(request.photos)
    }

    public func cancelRemoval() { removalRequest = nil }

    /// Moving files to the Trash takes time: it happens off the main actor.
    private func remove(_ removed: [Photo]) {
        guard !removed.isEmpty else { return }
        let (library, discard) = (library, discard)
        selection.subtract(removed.map(\.id))
        run {
            let thumbnails = ThumbnailStore(directory: library.previews)
            // The original first, the row after: a photo whose original could not be discarded
            // stays in the catalog, rather than leaving a file nothing points to any more.
            var failures: [String] = []
            for photo in removed {
                do {
                    let original = library.url(for: photo)
                    if FileManager.default.fileExists(atPath: original.path) { try discard(original) }
                    try library.catalog.remove([photo.id])
                    thumbnails.removeThumbnails(forPhoto: photo.id)
                } catch {
                    failures.append("\(photo.fileName): \(error.localizedDescription)")
                }
            }
            return failures
        } then: { [weak self] failures in
            guard let self else { return }
            if !failures.isEmpty {
                fail("Some photos could not be removed", "\(Count.photos(failures.count)) stayed in the library. \(failures[0])")
            }
            reloadPhotos(countsLibrary: true)
        }
    }

    // MARK: - Import

    public var isImporting: Bool { importProgress != nil }

    /// Imports the photos under `folder`, off the main actor, reporting progress.
    public func importFolder(_ folder: URL, preset: ImportPreset = ImportPreset.builtIns[0]) async -> ImportSummary {
        await importItems([folder], preset: preset)
    }

    /// Imports folders, however deep, and files; what is not a photo is left alone. A second
    /// import is refused while one runs. Progress comes back through a stream that this very
    /// function reads: nothing can light the overlay again once it has returned.
    public func importItems(_ items: [URL], preset: ImportPreset = ImportPreset.builtIns[0]) async -> ImportSummary {
        let importer = Importer(library: library, metadata: metadata)
        guard !isImporting else { return importer.run([]) }
        importProgress = ImportProgress(done: 0, total: 0, currentFile: "")
        let (steps, continuation) = AsyncStream<ImportProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            let scan = Self.survey(items)
            let files = scan.photos
            var summary = importer.run([])
            summary.ignored = scan.ignored
            // One file at a time, so that a cancellation is heard between two of them.
            for (index, file) in files.enumerated() where !Task.isCancelled {
                continuation.yield(ImportProgress(done: index, total: files.count, currentFile: file.lastPathComponent))
                let step = importer.run([file], preset: preset)
                summary.imported += step.imported
                summary.duplicates += step.duplicates
                summary.failures += step.failures
                summary.ignored += step.ignored
            }
            return summary
        }
        importTask = task
        for await step in steps { importProgress = step }
        let summary = await task.value
        let wasCancelled = task.isCancelled
        importTask = nil
        importProgress = nil
        reloadPhotos(countsLibrary: true)

        if let failure = summary.failures.first {
            fail("Some files could not be imported", "\(Count.photos(summary.failures.count)) failed. \(failure.file.lastPathComponent): \(failure.error.localizedDescription)")
        }
        let (imported, known) = (summary.imported.count, summary.duplicates.count)
        if wasCancelled {
            notice = "Import cancelled." + (imported > 0 ? " \(Count.photos(imported)) imported." : "")
        } else if imported > 0 {
            notice = "\(Count.photos(imported)) imported." + (known > 0 ? " \(Count.photos(known)) already in the library." : "")
        } else if known > 0 {
            notice = "Nothing new to import: \(Count.photos(known)) \(known == 1 ? "was" : "were") already in the library."
        } else if summary.failures.isEmpty {
            notice = "No photo was found there."
        }
        // A card also holds videos and text files: say that they were seen, and left.
        if let said = notice, !summary.ignored.isEmpty { notice = "\(said) \(Count.of(summary.ignored.count, "file")) ignored." }
        return summary
    }

    /// Stops after the file being copied; what was imported stays.
    public func cancelImport() { importTask?.cancel() }

    /// What folders and files hold: the photos, and what is there that is not one.
    private nonisolated static func survey(_ items: [URL]) -> (photos: [URL], ignored: [URL]) {
        var scan: (photos: [URL], ignored: [URL]) = ([], [])
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
            if values?.isDirectory == true {
                let found = Importer.survey(item)
                scan.photos += found.photos
                scan.ignored += found.ignored
            } else if let type = values?.contentType, Importer.importedTypes.contains(where: type.conforms(to:)) {
                scan.photos.append(item)
            } else {
                scan.ignored.append(item)
            }
        }
        return scan
    }

    public func dismissError() { errorMessage = nil }
    public func dismissNotice() { notice = nil }

    /// Good news from a neighbour of the library, shown where the library shows its own.
    public func say(_ text: String) { notice = text }

    private func fail(_ title: String, _ message: String) {
        errorTitle = title
        errorMessage = message
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { errorMessage = error.localizedDescription }
    }
}
