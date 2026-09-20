import AppKit
import CoreImage
import Foundation
import Observation
import RawEngine

/// How the image is scaled on screen.
public enum Zoom: Equatable, Sendable {
    case fit
    /// 100 %, around a focus point normalized to the image (origin top-left).
    case actualSize(center: CGPoint)
}

/// State of the develop window: the open file, its adjustments, and what to show.
/// Views only read and write this; everything image-related is delegated to `RawEngine`.
@MainActor
@Observable
public final class DevelopSession {
    public var adjustments = Adjustments() {
        didSet {
            guard adjustments != oldValue else { return }
            // The amount belongs to the look just applied: anything else ends it.
            if !isDosingLook { dosedLook = nil }
            scheduleSave()
            scheduleHistogram()
        }
    }
    /// Before/after: shows the neutral render without touching the adjustments.
    public var showsOriginal = false {
        didSet { if showsOriginal != oldValue { scheduleHistogram() } }
    }
    /// Distribution of the finished picture: what is exported, whatever part of it is on
    /// screen. Computed in the background: it trails a gesture by a frame or two, and never
    /// holds one up.
    public private(set) var histogram: Histogram?
    /// What the canvas is being used for.
    public var tool = Tool.none {
        didSet {
            guard tool != oldValue else { return }
            // What Escape goes back to: the framing as it was when the crop tool was picked.
            // The level is drawn inside the crop tool, so it does not reset that memory.
            if tool == .crop && oldValue != .level {
                framingBeforeCrop = adjustments.geometry
            } else if !isCropping {
                framingBeforeCrop = nil
            }
            // The crop is drawn on the whole frame.
            if isCropping { zoomToFit() }
            if oldValue != .none { commitEdit() }
        }
    }
    /// Crop mode: shows the whole frame, turned and straightened, so that the crop can be
    /// edited. Drawing a level line is part of it: same bar, same view of the frame.
    public var isCropping: Bool {
        get { tool == .crop || tool == .level }
        set { tool = newValue ? .crop : .none }
    }
    /// The named versions of the open photo, oldest first.
    public private(set) var versions: [SavedVersion] = []
    /// Whether this photo can keep versions: library photos can.
    public private(set) var canKeepVersions = false
    /// The history list is on screen.
    public var showsHistory = false
    /// A look being tried: the canvas shows it over the current settings, which it leaves alone.
    public var previewedPreset: Preset?
    /// The look just applied, while its amount can still be changed. Any other edit ends it.
    public private(set) var dosedLook: Preset?
    /// How much of `dosedLook` shows, from 0 to 1.
    public private(set) var lookAmount = 1.0
    /// The open photo as each look would make it, by look name.
    public private(set) var lookThumbnails: [String: CGImage] = [:]
    /// Whether the looks are on screen: thumbnails are only made while someone looks at them.
    public var showsLookThumbnails = false {
        didSet { if showsLookThumbnails, !oldValue { scheduleLookThumbnails() } }
    }
    /// Marks burnt highlights in red and blocked shadows in blue, on the picture. A view aid.
    public var showsClipping = false
    public var selectedLocalID: UUID?
    public var selectedSpotID: UUID?
    /// The healing line being drawn, while the pointer is still down.
    @ObservationIgnored var healingLineID: UUID?
    /// Moves whenever a mask the machine found arrives. The canvas draws from `adjustments`,
    /// and a raster sits outside them: this is how the view is told to draw again.
    public internal(set) var maskRevision = 0 {
        didSet { scheduleHistogram() }
    }
    /// How many of each sort of thing the machine found in the open photo, once it has
    /// looked. What the interface offers to choose between, and nothing at all when there is
    /// only one of them: a picker with one row is noise.
    public internal(set) var detectedInstances: [DetectedMask.Subject: Int] = [:]
    @ObservationIgnored var maskSearch: Task<Void, Never>?
    @ObservationIgnored let maskFinder = MaskFinder()
    /// What the machine found last time, on disk. Given from outside in tests, so that a run
    /// neither reads nor writes the folder a person's app uses.
    @ObservationIgnored var maskCache = MaskRasterCache.applicationSupport
    /// O: keeps the mask veil on, whatever the layer does.
    public var keepsMaskOverlay = false
    /// A handle is being dragged or a stroke painted. Over when the edit settles.
    var isEditingMask = false
    /// Brush size, in fractions of the long edge, and whether it paints or erases.
    public var brushRadius = 0.05
    public var isErasing = false
    /// Ratio the crop tool holds while a corner is dragged.
    public var cropAspect = CropAspect.free
    /// The ratio is held against the orientation of the frame: a vertical crop of a horizontal shot.
    public private(set) var cropAspectIsTurned = false
    public private(set) var zoom = Zoom.fit
    public private(set) var errorMessage: String?
    /// What failed, in a few words: the title of the alert that shows `errorMessage`.
    public private(set) var errorTitle = "Something did not work"
    /// Good news, shown for a moment: an export that went through.
    public private(set) var notice: String?
    public private(set) var isExporting = false

    /// Looks and export presets, as last read from their folders.
    public private(set) var presets: [Preset]
    public private(set) var exportPresets: [ExportPreset]

    fileprivate(set) var source: RawSource?
    /// Settings copied from a photo, waiting to be pasted onto another.
    private var clipboard: Preset?
    @ObservationIgnored private let analyzer = HistogramAnalyzer()
    /// The picture developed at full size, for the 100 % view to pan over without developing
    /// it again on every step. Only valid for the settings it was made with.
    @ObservationIgnored private var zoomCache: (key: Adjustments, image: CIImage)?
    @ObservationIgnored private let zoomWorker = ZoomCacheWorker()
    @ObservationIgnored private var zoomCacheTask: Task<Void, Never>?
    @ObservationIgnored private var wantedZoomCache: (url: URL, adjustments: Adjustments)?
    /// How many times the picture was developed at full size for the zoom. For tests.
    public private(set) var fullSizeRenderCount = 0
    @ObservationIgnored public private(set) var isServingZoomFromCache = false
    /// Quiet time before the full-size picture is developed: not while a slider moves.
    private static let zoomCacheDelay = Duration.milliseconds(200)

    @ObservationIgnored private let histogramWorker = HistogramWorker()
    @ObservationIgnored private let lookWorker = LookPreviewWorker()
    @ObservationIgnored private var lookTask: Task<Void, Never>?
    @ObservationIgnored private var histogramTask: Task<Void, Never>?
    @ObservationIgnored private var wantedHistogram: (url: URL, adjustments: Adjustments)?
    @ObservationIgnored private let presetStore: JSONFileStore<Preset>
    @ObservationIgnored private let exportPresetStore: JSONFileStore<ExportPreset>
    /// The folder the moods are read from.
    @ObservationIgnored private let luts: LUTLibrary
    @ObservationIgnored private let writer: EditWriter?
    /// The scale the preview is being decoded at, kept so that a gesture can hold on to it.
    /// Forgotten with the photo: another file is another size.
    @ObservationIgnored private var decodeScale: Float?
    @ObservationIgnored private let versionStore: (any VersionStore)?
    @ObservationIgnored private let historyStore: (any HistoryStore)?
    @ObservationIgnored private var savedHistory: SavedHistory?
    @ObservationIgnored private var autosavesInFlight = 0
    @ObservationIgnored private var autosaveWaiters: [CheckedContinuation<Void, Never>] = []
    /// What the sidecar of the open photo holds: saving is skipped when nothing changed.
    @ObservationIgnored private var persisted = Adjustments()
    @ObservationIgnored private var framingBeforeCrop: Geometry?
    /// The settings a dosed look is recomputed from, so that sliding its amount back and
    /// forth never piles the look onto itself.
    @ObservationIgnored private var lookBase = Adjustments()
    /// Set while the amount writes the settings, which must not take the look away.
    @ObservationIgnored private var isDosingLook = false
    @ObservationIgnored private var reportedRenderFailure = false
    /// The name the step being taken was given, if it was.
    @ObservationIgnored private var pendingLabel: String?
    /// Undo history of the open photo.
    private var history = EditHistory(Adjustments())
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// Long edge of the image the histogram is computed on. Plenty for 256 bins, and cheap.
    private static let histogramSize = CGSize(width: 512, height: 512)
    /// Quiet time after the last edit before it is written to disk and becomes an undo step.
    private static let saveDelay = Duration.milliseconds(500)

    /// - Parameter sidecars: where edits are kept between sessions; `nil` keeps nothing.
    public init(
        presets: JSONFileStore<Preset> = PresetLibrary.presets,
        exportPresets: JSONFileStore<ExportPreset> = PresetLibrary.exportPresets,
        luts: LUTLibrary = .applicationSupport,
        sidecars: (any AdjustmentsPersistence)? = nil,
        versions: (any VersionStore)? = nil,
        history: (any HistoryStore)? = nil
    ) {
        self.luts = luts
        versionStore = versions
        historyStore = history
        presetStore = presets
        exportPresetStore = exportPresets
        writer = sidecars.map(EditWriter.init)
        self.presets = presets.all()
        self.exportPresets = exportPresets.all()
    }

    public var info: RawInfo? { source?.info }
    public var fileName: String? { source?.url.lastPathComponent }
    public var sliderContext: SliderContext? { info.map(SliderContext.init) }
    public var hasChanges: Bool { adjustments != Adjustments() }

    /// A failed open keeps the current document: a bad drop should not close your work.
    /// The edits of the photo being left are saved; those of the new one are restored.
    /// - Returns: whether `url` is now the open photo. Settings that cannot be read do not
    ///   prevent that: the photo opens untouched, and the error says why.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        do {
            let opened = try RawSource(url: url)
            flush()
            source = opened
            decodeScale = nil
            detectedInstances = [:]
            errorMessage = nil
            var restored = Adjustments()
            do {
                restored = try writer?.load(for: url) ?? Adjustments()
            } catch {
                // The photo still opens, untouched; the damaged file stays until an edit replaces it.
                report(error)
            }
            persisted = restored
            adjustments = restored
            history = restoredHistory(of: url, leadingTo: restored)
            reportedRenderFailure = false
            showsOriginal = false
            tool = .none
            selectedLocalID = nil
            selectedSpotID = nil
            zoom = .fit
            histogram = nil
            dropZoomCache()
            scheduleHistogram()
            previewedPreset = nil
            dosedLook = nil
            reloadVersions()
            lookThumbnails = [:]
            scheduleLookThumbnails()
            // What the machine found for the photo before is not what it will find for this
            // one, and the layers of this one are asking already.
            maskSearch?.cancel()
            maskSearch = nil
            findMasks()
            return true
        } catch {
            report(error, title: "This file could not be opened")
            return false
        }
    }

    // MARK: - Persistence

    /// Writes pending edits now, and waits for them. Called before leaving a photo and on
    /// quit; in between, edits are saved in the background shortly after the last one.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        commitEdit()
        saveHistory()
        guard let writer, let url = source?.url, adjustments != persisted else { return }
        do {
            try writer.writeNow(adjustments, for: url)
            persisted = adjustments
        } catch {
            report(error, title: "Your edits could not be saved")
        }
    }

    /// What the quiet time after an edit leads to: an undo step, and a save that does not
    /// hold the main actor, since the next gesture has often begun by then.
    func autosave() {
        pendingSave = nil
        commitEdit()
        guard let writer, let url = source?.url, adjustments != persisted else { return }
        let saved = adjustments
        let before = persisted
        persisted = saved
        autosavesInFlight += 1
        writer.write(saved, for: url) { [weak self] failure in
            guard let self else { return }
            if let failure {
                // Forget that it was saved, so that the next save tries again.
                if self.persisted == saved { self.persisted = before }
                self.report(failure, title: "Your edits could not be saved")
            }
            self.autosavesInFlight -= 1
            if self.autosavesInFlight == 0 {
                self.autosaveWaiters.forEach { $0.resume() }
                self.autosaveWaiters = []
            }
        }
    }

    /// Resolves once no background save is on its way. For tests.
    func autosaveSettled() async {
        guard autosavesInFlight > 0 else { return }
        await withCheckedContinuation { autosaveWaiters.append($0) }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.autosave()
        }
    }

    // MARK: - Looks

    /// Applies a look, and opens its amount: until the next edit, how much of it shows can
    /// still be changed. The step is taken when the dosing settles, as for any gesture, so
    /// that applying a look and dosing it is one undo away.
    public func apply(_ preset: Preset) {
        commitEdit()
        lookBase = adjustments
        dose(preset, amount: 1)
    }

    /// Recomputes the settings from those of before the look, rather than from what is on
    /// screen: the look never piles onto itself, whichever way the slider goes.
    /// - Parameter amount: from 0 (the photo as it was) to 1 (the look applied whole).
    public func setLookAmount(_ amount: Double) {
        guard let dosedLook else { return }
        dose(dosedLook, amount: amount)
    }

    private func dose(_ preset: Preset, amount: Double) {
        let amount = min(max(amount, 0), 1)
        isDosingLook = true
        adjustments = preset.applied(to: lookBase, amount: amount, asShot: info?.asShotWhiteBalance)
        isDosingLook = false
        (dosedLook, lookAmount) = (preset, amount)
        pendingLabel = "Look: \(preset.name)"
    }

    /// Saves the chosen groups of the current settings as a look. Blank names are ignored.
    /// The look `name` would be written over, spelled as it is: what the sheet asks about
    /// before replacing it. `nil` when the name is free. Case does not make two looks: on the
    /// volumes macOS formats, "Fade" and "fade" are one file.
    public func lookToOverwrite(named name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.name
    }

    /// - Parameter overwriting: agreed to replace a look of that name. Without it, a name
    ///   that is taken keeps its look: nobody loses one by typing a name twice.
    public func savePreset(named name: String, groups: Set<AdjustmentGroup>, overwriting: Bool = false) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !groups.isEmpty else { return }
        guard overwriting || lookToOverwrite(named: name) == nil else { return }
        do {
            try presetStore.save(Preset(name: name, capturing: adjustments, groups: groups))
            presets = presetStore.all()
        } catch {
            report(error)
        }
    }

    // MARK: - History between sessions

    /// The history kept for this photo, if it still leads to the photo as it is: settings
    /// changed elsewhere (a look applied from the grid) make it a story about another picture.
    private func restoredHistory(of url: URL, leadingTo current: Adjustments) -> EditHistory<Adjustments> {
        savedHistory = nil
        guard let saved = try? historyStore?.history(of: url),
              let kept = EditHistory(steps: saved.steps.map { .init(state: $0.adjustments, label: $0.label) }, cursor: saved.cursor),
              kept.committed == current else { return EditHistory(current) }
        savedHistory = saved
        return kept
    }

    /// Written when the photo is left, not at every step: it is read once, at the next opening.
    private func saveHistory() {
        guard let historyStore, let url = source?.url else { return }
        let current = SavedHistory(steps: history.steps.map { .init(label: $0.label, adjustments: $0.state) }, cursor: history.cursor)
        guard current != savedHistory, current.steps.count > 1 else { return }
        do {
            try historyStore.save(current, for: url)
            savedHistory = current
        } catch {
            // A comfort, not the photo's edits: those are saved, and said if they are not.
        }
    }

    // MARK: - Versions

    private func reloadVersions() {
        guard let url = source?.url, let kept = try? versionStore?.versions(of: url) else {
            (versions, canKeepVersions) = ([], false)
            return
        }
        (versions, canKeepVersions) = (kept, true)
    }

    /// Keeps the current settings under a name, next to the others. Blank names are ignored.
    public func saveVersion(named name: String) {
        guard canKeepVersions, let url = source?.url, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        changeVersions { try $0.save(adjustments, named: name, for: url) }
    }

    /// The photo becomes that version, as one step: what was on screen is an undo away.
    public func show(_ version: SavedVersion) {
        perform("Version: \(version.name)") { adjustments = version.adjustments }
    }

    /// Whether the settings are those of `version`: the one on screen.
    public func isShown(_ version: SavedVersion) -> Bool { version.adjustments == adjustments }

    public func renameVersion(_ version: SavedVersion, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        changeVersions { try $0.rename(version.id, to: name) }
    }

    public func deleteVersion(_ version: SavedVersion) {
        changeVersions { try $0.delete(version.id) }
    }

    private func changeVersions(_ change: (any VersionStore) throws -> Void) {
        guard let versionStore else { return }
        do {
            try change(versionStore)
        } catch {
            report(error, title: "This version could not be saved")
        }
        reloadVersions()
    }

    /// The groups of settings away from neutral, among those a look may carry: what saving
    /// the current settings as a look proposes.
    public var editedGroups: Set<AdjustmentGroup> {
        AdjustmentGroup.defaultSelection.filter { adjustments.applying(Adjustments(), groups: [$0]) != adjustments }
    }

    /// Whether the settings already are what `preset` would make them: the look in use.
    public func isApplied(_ preset: Preset) -> Bool {
        guard hasChanges else { return false }
        var applied = adjustments
        preset.apply(to: &applied)
        return applied == adjustments
    }

    /// Thumbnails follow the photo and its settings, once these have settled: never during a
    /// gesture, which has the GPU to itself.
    private func scheduleLookThumbnails() {
        guard showsLookThumbnails, let url = source?.url else { return }
        let (base, looks) = (adjustments, presets)
        lookTask?.cancel()
        lookTask = Task { [weak self, lookWorker] in
            let rendered = await lookWorker.thumbnails(of: url, base: base, looks: looks)
            guard !Task.isCancelled, let self, self.source?.url == url else { return }
            self.lookThumbnails = rendered
        }
    }

    /// Resolves once the thumbnails reflect the current settings. For tests.
    func lookThumbnailsSettled() async {
        await lookTask?.value
    }

    /// Whether this look is a file of yours. Looks are passed around as files: one dropped
    /// into the folder is recognised by the file it came from, not by its name, so that a
    /// look named after a built-in is still yours to delete.
    public func canDelete(_ preset: Preset) -> Bool {
        presetStore.entries().contains { $0.item.name == preset.name && !$0.isBuiltIn }
    }

    public func deletePreset(_ preset: Preset) {
        do {
            try presetStore.delete(named: preset.name)
            presets = presetStore.all()
        } catch {
            report(error)
        }
    }

    // MARK: - Mood

    /// The `.cube` files of the LUTs folder, as last read. The folder is the source of
    /// truth: nothing is cached between looks, so a file dropped in shows up on the next one.
    public private(set) var moodNames: [String] = []

    /// How much of the mood shows, from 0 to 100. Without a mood, the position a picked one
    /// would start at.
    public var moodAmount: Double { adjustments.lut?.amount ?? 100 }

    public func reloadMoodNames() {
        moodNames = luts.names()
    }

    /// Picks a mood, or takes it away. The amount that was on screen is kept: trying several
    /// moods at 60 % is what the list is for.
    public func setMood(_ name: String?) {
        let amount = moodAmount
        perform(name.map { "Mood: \($0)" } ?? "No Mood") {
            adjustments.lut = name.map { LUTSetting(name: $0, amount: amount) }
        }
    }

    /// Not a step of its own: the amount is dragged, and settles like any slider.
    public func setMoodAmount(_ amount: Double) {
        guard adjustments.lut != nil else { return }
        adjustments.lut?.amount = min(max(amount, 0), 100)
    }

    /// Shows the folder in the Finder: moods are files, and saying so is the only way
    /// anybody puts one there.
    public func revealMoodFolder() {
        let folder = luts.directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: - Copy and paste

    public var canPaste: Bool { clipboard != nil && source != nil }

    /// What was copied, for the library to paste it on a selection.
    public var copiedSettings: Preset? { clipboard }

    /// What a copy takes. Chosen once, then kept: a series is usually pasted the same way.
    public var copiedGroups = AdjustmentGroup.defaultSelection
    /// The sheet that chooses them is up.
    public var isChoosingCopiedGroups = false

    public func copyAdjustments() {
        copyAdjustments(groups: copiedGroups)
    }

    public func copyAdjustments(groups: Set<AdjustmentGroup>) {
        clipboard = Preset(name: "Clipboard", capturing: adjustments, groups: groups)
    }

    /// Copies the settings of a photo that is not the open one: the grid copies too.
    public func copySettings(of adjustments: Adjustments, groups: Set<AdjustmentGroup>) {
        clipboard = Preset(name: "Clipboard", capturing: adjustments, groups: groups)
    }

    public func pasteAdjustments() {
        guard source != nil else { return }
        perform("Paste Settings") { clipboard?.apply(to: &adjustments) }
    }

    // MARK: - Export

    public func suggestedFileName(for preset: ExportPreset) -> String? {
        source.map { preset.fileName(for: $0.url) }
    }

    /// The export being set up, and whether its sheet is on screen. A preset is its starting
    /// point; everything about it can be changed before the file is written.
    public var exportDraft: ExportPreset?

    /// What the catalog says about the open photo, written into the file it is exported to.
    /// Given by `AppSession` when a photo of the library is opened; empty for a loose file,
    /// which nothing says anything about. The develop session knows no catalog.
    public var credits = PhotoCredits()

    /// What the file would be called as things stand: it follows the format and the template,
    /// so that a .jpg never holds a TIFF.
    public var exportFileName: String? {
        exportDraft.flatMap(suggestedFileName(for:))
    }

    public func beginExport(with preset: ExportPreset) {
        guard source != nil else { return }
        exportDraft = preset
    }

    public func cancelExport() {
        exportDraft = nil
    }

    /// Keeps what is being set up as a preset of its own, under a name of its own: nobody is
    /// going to write JSON by hand to export at 1600 px. The sheet stays open, on what was
    /// just saved. Blank names keep nothing.
    public func saveExportPreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var draft = exportDraft else { return }
        draft.name = name
        draft.options = draft.options.sanitized()
        do {
            try exportPresetStore.save(draft)
            exportPresets = exportPresetStore.all()
            exportDraft = draft
        } catch {
            report(error, title: "This export preset could not be saved")
        }
    }

    /// Presets that ship with the app stay; a file dropped in by hand is recognised by its
    /// file, not by its name.
    public func canDeleteExportPreset(_ preset: ExportPreset) -> Bool {
        exportPresetStore.entries().contains { $0.item.name == preset.name && !$0.isBuiltIn }
    }

    public func deleteExportPreset(_ preset: ExportPreset) {
        do {
            try exportPresetStore.delete(named: preset.name)
            exportPresets = exportPresetStore.all()
            if exportDraft?.name == preset.name { exportDraft = nil }
        } catch {
            report(error)
        }
    }

    public func reset() {
        perform("Reset") { adjustments = Adjustments() }
    }

    // MARK: - Tools

    /// Leaves the current tool and gives up what it was doing. For the crop tool, the framing
    /// goes back to what it was when the tool was picked; the other tools have nothing pending.
    public func cancelTool() {
        if tool == .crop, let framingBeforeCrop {
            adjustments.geometry = framingBeforeCrop
        }
        tool = .none
    }

    // MARK: - White balance

    /// What the eyedropper does: the surface under `point` becomes neutral, and the tool is
    /// put down, since one click is the whole gesture.
    public func pickWhiteBalance(at point: NormalizedPoint) {
        guard let source, let picked = source.whiteBalance(neutralAt: point) else { return }
        perform {
            adjustments.setTemperature(picked.temperature.rounded(), asShot: source.info.asShotWhiteBalance)
            adjustments.setTint(picked.tint.rounded(), asShot: source.info.asShotWhiteBalance)
        }
        tool = .none
    }

    public func apply(_ preset: WhiteBalancePreset) {
        guard let asShot = info?.asShotWhiteBalance else { return }
        perform("White Balance: \(preset.rawValue)") { preset.apply(to: &adjustments, asShot: asShot) }
    }

    /// The preset the current settings correspond to; `nil` once the sliders have moved off it.
    public var whiteBalancePreset: WhiteBalancePreset? { WhiteBalancePreset.matching(adjustments) }

    // MARK: - Auto

    /// Sets the light sliders and vibrance from an analysis of the picture itself, as the
    /// decoder renders it: the result does not depend on where the sliders were.
    public func autoTone() {
        guard let source else { return }
        do {
            // The engine's one way of analysing a photo: the app and the command line agree.
            let result = try AutoTone.settings(for: source)
            perform("Auto") { result.apply(to: &adjustments) }
        } catch {
            // A button that does nothing looks broken: say that it tried.
            report(error, title: "Auto could not analyse this photo")
        }
    }

    // MARK: - Undo

    public var canUndo: Bool { history.canUndo(from: adjustments) }
    public var canRedo: Bool { history.canRedo(from: adjustments) }

    /// Turns whatever changed since the last step into one undo step. A slider drag or a
    /// brush stroke changes the document dozens of times and must undo at once: steps are
    /// taken when edits settle (with the autosave), and around every discrete action.
    public func commitEdit() {
        if isEditingMask { isEditingMask = false }
        // Not worth waking every observer of the history when nothing changed.
        guard adjustments != history.committed else { return }
        history.commit(adjustments, label: stepLabel)
        pendingLabel = nil
        scheduleLookThumbnails()
    }

    /// What the step being taken is called: the name it was given, else what changed, in
    /// words. Undoing a look that was still being dosed must still say which look it was.
    private var stepLabel: String { pendingLabel ?? describedChange }

    /// What changed since the last step, in words, for the history.
    private var describedChange: String {
        guard let context = sliderContext else { return "Edit" }
        return EditDescriber.label(from: history.committed, to: adjustments, context: context)
    }

    /// The steps of the history, oldest first, and the one the photo is at.
    public var historySteps: [HistoryStep] {
        history.steps.enumerated().map { HistoryStep(id: $0.offset, label: $0.element.label) }
    }

    public var historyCursor: Int { history.cursor }

    /// Goes back, or forward, to any step. What follows it stays, until the next edit.
    public func goToHistoryStep(_ index: Int) {
        guard let state = history.jump(to: index, from: adjustments, pendingLabel: stepLabel) else { return }
        pendingLabel = nil
        adjustments = state
        dropStaleSelection()
    }

    public func undo() {
        guard let previous = history.undo(from: adjustments, pendingLabel: stepLabel) else { return }
        pendingLabel = nil
        adjustments = previous
        dropStaleSelection()
    }

    public func redo() {
        guard let next = history.redo(from: adjustments) else { return }
        adjustments = next
        dropStaleSelection()
    }

    /// Runs a discrete action (a button, a menu command) as an undo step of its own.
    /// - Parameter label: what the history calls it, when the change alone does not say
    ///   ("Look: Black & white" rather than "Several Settings").
    public func perform(_ label: String? = nil, _ action: () -> Void) {
        commitEdit()
        action()
        pendingLabel = label
        commitEdit()
        pendingLabel = nil
    }

    /// Undoing the creation of a layer or a spot must not leave it selected.
    private func dropStaleSelection() {
        if !adjustments.locals.contains(where: { $0.id == selectedLocalID }) { selectedLocalID = nil }
        if !adjustments.spots.contains(where: { $0.id == selectedSpotID }) { selectedSpotID = nil }
    }

    /// For failures that happen in a view (an export started from a panel, for instance).
    public func report(_ error: Error, title: String = "Something did not work") {
        errorTitle = title
        errorMessage = error.localizedDescription
    }

    public func dismissNotice() {
        notice = nil
    }

    public func dismissError() {
        errorMessage = nil
    }

    /// The image to display: fitted in the view, or at 100 %, in which case it is the
    /// full-resolution image cut down to what the view can show.
    /// - Parameter viewSize: in pixels.
    public func previewImage(fitting viewSize: CGSize) -> CIImage? {
        guard let source else { return nil }
        let displayed = displayedAdjustments

        guard case .actualSize(let center) = zoom else {
            return fittedImage(displayed, fitting: viewSize).map(withMaskOverlay).map(withClipping).map(withSoftProof)
        }
        // The cached picture if it matches the settings; else the visible area developed on
        // the spot, which shows a change at once, while the cache is rebuilt in the background.
        let cached = zoomCache.flatMap { $0.key == displayed ? $0.image : nil }
        isServingZoomFromCache = cached != nil
        if cached == nil { scheduleZoomCache(for: displayed) }
        guard let image = cached ?? developed({ try source.image(adjustments: displayed) }) else { return nil }
        let visible = ZoomGeometry.visibleRect(of: image.extent.size, in: viewSize, centeredOn: center)
        // `visible` has its origin at the top-left; Core Image at the bottom-left.
        let region = CGRect(x: visible.minX, y: image.extent.height - visible.maxY, width: visible.width, height: visible.height)
        return withSoftProof(withClipping(withMaskOverlay(image).cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))))
    }

    // MARK: - Soft proofing

    /// The paper the picture is being judged against, or `nil` for the screen's own colours.
    /// A **viewing condition**, not a setting: nothing of it is stored with the photo, and it
    /// changes no exported file.
    public private(set) var softProofProfile: PrintProfile?
    /// Paints in flat grey what the paper cannot hold.
    public private(set) var softProofWarnsAboutGamut = false
    /// The profiles this machine holds, read once: ColorSync's folders do not change while
    /// the app runs, and reading them costs a directory listing each.
    @ObservationIgnored public private(set) lazy var printProfiles: [PrintProfile] = ProfileLibrary.profiles()
    /// Built from the profile, off the main actor: the table costs a few hundred milliseconds.
    @ObservationIgnored private var softProof: SoftProof?
    @ObservationIgnored private var softProofTask: Task<Void, Never>?

    /// Shows the picture through a paper profile, or goes back to the screen with `nil`.
    public func setSoftProof(_ profile: PrintProfile?, warnsAboutGamut: Bool? = nil) {
        softProofProfile = profile
        if let warnsAboutGamut { softProofWarnsAboutGamut = warnsAboutGamut }
        rebuildSoftProof()
    }

    public func setSoftProofWarnsAboutGamut(_ warns: Bool) {
        setSoftProof(softProofProfile, warnsAboutGamut: warns)
    }

    /// Resolves once the proof reflects the profile chosen. For tests and scripts.
    public func softProofSettled() async {
        while let task = softProofTask { await task.value }
    }

    private func rebuildSoftProof() {
        softProofTask?.cancel()
        softProof = nil
        guard let profile = softProofProfile else {
            softProofTask = nil
            return
        }
        let warns = softProofWarnsAboutGamut
        softProofTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                SoftProof(profile: profile, warnsAboutGamut: warns)
            }.value
            guard let self, !Task.isCancelled else { return }
            // The photographer may have moved on while the table was being built.
            if softProofProfile == profile && softProofWarnsAboutGamut == warns { softProof = built }
            softProofTask = nil
        }
    }

    /// Nothing until the table is built: a picture shown through the wrong colours for a
    /// moment would be worse than one shown a moment late.
    private func withSoftProof(_ image: CIImage) -> CIImage {
        softProof?.applied(to: image) ?? image
    }

    private func withClipping(_ image: CIImage) -> CIImage {
        showsClipping && !showsOriginal ? ClippingOverlay.apply(to: image) : image
    }

    /// Develops the picture at full size once the settings have been quiet for a moment.
    private func scheduleZoomCache(for adjustments: Adjustments) {
        guard let url = source?.url, wantedZoomCache?.adjustments != adjustments || wantedZoomCache?.url != url else { return }
        wantedZoomCache = (url, adjustments)
        zoomCacheTask?.cancel()
        zoomCacheTask = Task { [weak self] in
            try? await Task.sleep(for: Self.zoomCacheDelay)
            guard !Task.isCancelled, let self, let wanted = self.wantedZoomCache else { return }
            let developed = await self.zoomWorker.develop(wanted.url, adjustments: wanted.adjustments)
            guard !Task.isCancelled, let developed, self.source?.url == wanted.url, case .actualSize = self.zoom else { return }
            self.zoomCache = (wanted.adjustments, CIImage(cgImage: developed))
            self.fullSizeRenderCount += 1
        }
    }

    /// Resolves once the full-size picture is ready, or will not be. For tests.
    public func zoomCacheSettled() async {
        await zoomCacheTask?.value
    }

    private func dropZoomCache() {
        zoomCacheTask?.cancel()
        zoomCacheTask = nil
        wantedZoomCache = nil
        zoomCache = nil
        isServingZoomFromCache = false
    }

    /// Switches between the fitted view and 100 % around `point`, normalized to the image.
    public func toggleZoom(at point: CGPoint) {
        if zoom == .fit { zoomToActualSize(at: point) } else { zoomToFit() }
    }

    /// 100 % around `point`. Already at 100 %, the view stays where it was panned to.
    public func zoomToActualSize(at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        guard source != nil, zoom == .fit, tool != .crop else { return }
        zoom = .actualSize(center: point)
    }

    public func zoomToFit() {
        guard zoom != .fit else { return }
        zoom = .fit
        // A full-size picture is a hundred megabytes: it goes when the zoom does.
        dropZoomCache()
    }

    /// Moves the 100 % view. `delta` is normalized to the image; positive values reveal what
    /// lies further right and down.
    public func pan(by delta: CGSize) {
        guard case .actualSize(let center) = zoom else { return }
        zoom = .actualSize(center: CGPoint(
            x: min(max(center.x + delta.width, 0), 1),
            y: min(max(center.y + delta.height, 0), 1)
        ))
    }

    /// Full-resolution size of the picture as it is shown: turned, straightened and cropped.
    public var shownImageSize: CGSize? {
        info.map { displayedAdjustments.geometry.outputSize(for: $0.imageSize) }
    }

    /// Where the picture the tools work on sits in a canvas of `size` points: fitted, or, at
    /// 100 %, the larger frame the canvas is a window on.
    func toolFrame(in size: CGSize, backingScale: CGFloat) -> CGRect {
        guard let shown = shownImageSize, shown.height > 0 else { return .zero }
        guard case .actualSize(let center) = zoom else {
            return FitGeometry.frame(forAspect: shown.width / shown.height, in: size, padding: FitGeometry.padding)
        }
        return ZoomGeometry.imageFrame(of: shown, centeredOn: center, in: size, padding: FitGeometry.padding, backingScale: backingScale)
    }

    /// Full-resolution size of the frame the crop is relative to.
    public var cropFrameSize: CGSize? {
        info.map { adjustments.geometry.frameSize(for: $0.imageSize) }
    }

    /// Switches the crop tool to a ratio, and re-crops to the largest area that has it.
    /// What the crop overlay holds while a handle is dragged.
    public var lockedCropAspect: Double? {
        cropFrameSize.flatMap { cropAspect.normalizedAspect(in: $0, turned: cropAspectIsTurned) }
    }

    /// From landscape to portrait and back, for the ratio in use.
    public func turnCropAspect() {
        cropAspectIsTurned.toggle()
        apply(cropAspect)
    }

    public func apply(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let frame = cropFrameSize, let normalized = aspect.normalizedAspect(in: frame, turned: cropAspectIsTurned) else { return }
        perform { adjustments.geometry.crop = .largest(withAspect: normalized) }
    }

    public func turn(clockwise: Bool) {
        perform { adjustments.geometry.turn(clockwise: clockwise) }
    }

    /// Straightens the picture so that the line just drawn becomes level, and puts the level
    /// down again. One undo step, like every other button-driven edit.
    ///
    /// The points are the view's own, and no conversion is needed: the canvas shows the frame
    /// fitted, so a point of the view is the same number of pixels across as it is down, which
    /// is all an angle asks for. A line too short to mean anything changes nothing.
    public func level(from start: CGPoint, to end: CGPoint) {
        defer { tool = .crop }
        guard let degrees = LevelTool.straightening(from: start, to: end) else { return }
        perform {
            adjustments.geometry.straighten = LevelTool.straighten(adjustments.geometry.straighten, by: degrees)
        }
    }

    /// The crop bar's Reset: turns, straightening and the frame, which is what that bar shows.
    /// The keystone correction is a lens correction with a panel of its own, and each of its
    /// sliders resets there: a button never undoes something it does not show.
    public func resetGeometry() {
        perform {
            adjustments.geometry = Geometry.perspective(adjustments.geometry.perspective)
        }
    }

    // MARK: - Histogram

    /// Asks for a histogram of the picture as it is now. Requests made while one is being
    /// computed collapse into the latest: a drag never queues up stale work.
    private func scheduleHistogram() {
        guard let url = source?.url else {
            histogram = nil
            return
        }
        wantedHistogram = (url, finishedAdjustments)
        guard histogramTask == nil else { return }
        histogramTask = Task { [weak self] in
            while let self, let (url, adjustments) = self.wantedHistogram {
                self.wantedHistogram = nil
                let result = await self.histogramWorker.histogram(of: url, adjustments: adjustments)
                // The photo may have changed while this one was being computed.
                if self.source?.url == url { self.histogram = result }
            }
            self?.histogramTask = nil
        }
    }

    /// Resolves once the histogram reflects the current settings. For tests and scripts.
    public func histogramSettled() async {
        while let task = histogramTask { await task.value }
    }

    /// Full-resolution export, off the main actor. It opens the file again rather than
    /// sharing the on-screen decoder, which is not thread-safe.
    public func export(to destination: URL, options: ExportOptions = ExportOptions()) async throws {
        guard let url = source?.url else { return }
        let (adjustments, credits) = (adjustments, credits)
        isExporting = true
        defer { isExporting = false }
        try await Task.detached(priority: .userInitiated) {
            let source = try RawSource(url: url)
            try Renderer.shared.write(source.image(adjustments: adjustments), to: destination, options: options, credits: credits)
        }.value
        notice = "Exported to “\(destination.lastPathComponent)”."
    }

    /// Decoded at the resolution a view of `viewSize` pixels needs: what counts is the size of
    /// what is shown, so a tight crop is decoded at a higher scale.
    private func fittedImage(_ adjustments: Adjustments, fitting viewSize: CGSize) -> CIImage? {
        guard let source else { return nil }
        let shownSize = adjustments.geometry.outputSize(for: source.info.imageSize)
        // Held still while a gesture runs: the scale follows the size of the frame, and
        // changing it decodes the RAW again. `pendingSave` is already the app's own word for
        // "a gesture is in flight" — it is what the autosave waits for.
        let scale = PreviewScale.held(
            decodeScale,
            wanting: PreviewScale.factor(for: shownSize, fitting: viewSize),
            isSettled: pendingSave == nil
        )
        decodeScale = scale
        return developed { try source.image(adjustments: adjustments, scaleFactor: scale) }
    }

    /// A picture that cannot be developed leaves the canvas empty: that is said once per
    /// photo, not once per frame, and never from inside the frame being drawn.
    private func developed(_ develop: () throws -> CIImage) -> CIImage? {
        do {
            return try develop()
        } catch {
            guard !reportedRenderFailure else { return nil }
            reportedRenderFailure = true
            Task { [weak self] in self?.report(error, title: "This photo could not be developed") }
            return nil
        }
    }

    /// The picture as it will be exported, or untouched while comparing with the original.
    private var finishedAdjustments: Adjustments {
        guard !showsOriginal else { return Adjustments() }
        guard let previewedPreset else { return adjustments }
        var tried = adjustments
        previewedPreset.apply(to: &tried)
        return tried
    }

    /// What the canvas shows: the finished picture, except in tools that need more of it.
    /// The crop tool keeps the whole frame visible around the crop; local tools show the
    /// original frame, since that is what masks and spots are positioned in.
    private var displayedAdjustments: Adjustments {
        var displayed = finishedAdjustments
        switch tool {
        case .none: break
        // The level is drawn on the same view of the frame as the crop, so that a horizon
        // cut off by the crop can still be drawn along.
        case .crop, .level: displayed.geometry.crop = nil
        case .local, .spots, .whiteBalance: displayed.geometry = Geometry()
        }
        return displayed
    }
}
