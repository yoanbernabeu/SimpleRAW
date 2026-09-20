import CoreImage
import Foundation
import RawEngine

/// What the canvas is being used for. Every tool but `.none` shows the picture fitted.
public enum Tool: Hashable, Sendable {
    case none, crop, local, spots, whiteBalance
    /// Drawing a line along something that ought to be level. Part of the crop tool: the
    /// picture is framed the same way and the same bar is on screen.
    case level
}

extension MaskKind {
    var systemImage: String {
        switch self {
        case .linear: "rectangle.tophalf.inset.filled"
        case .radial: "circle.dashed"
        case .brush: "paintbrush.pointed"
        case .subject: "cube.transparent"
        case .person: "person.and.background.dotted"
        }
    }
}

extension DevelopSession {
    // MARK: - Masks

    public var selectedLocal: LocalAdjustment? {
        adjustments.locals.first { $0.id == selectedLocalID }
    }

    /// Adds a mask with a sensible starting shape, selects it and switches to the local tool.
    public func addLocal(_ kind: MaskKind) {
        guard let frame = info?.imageSize, frame.width > 0, frame.height > 0 else { return }
        let mask: Mask = switch kind {
        case .linear:
            // The classic sky filter: full at the top, gone by mid-height.
            .linear(LinearMask(start: .init(x: 0.5, y: 0.2), end: .init(x: 0.5, y: 0.5)))
        case .radial:
            // A quarter of the long edge, expressed per axis so that it is round on screen.
            .radial(RadialMask(
                center: .init(x: 0.5, y: 0.5),
                radiusX: 0.25 * max(frame.width, frame.height) / frame.width,
                radiusY: 0.25 * max(frame.width, frame.height) / frame.height
            ))
        case .brush:
            .brush(BrushMask())
        case .subject, .person:
            // Nothing to shape: the machine is asked, and until it answers the layer is a
            // black mask, which changes nothing.
            .detected(DetectedMask(subject: kind == .person ? .person : .subject))
        }
        let local = LocalAdjustment(mask: mask)
        perform { adjustments.locals.append(local) }
        selectedLocalID = local.id
        tool = .local
        if kind.isDetected { findMasks() }
    }

    /// Whether a found mask has its picture yet. Until it does, the layer changes nothing.
    public func hasRaster(for mask: DetectedMask) -> Bool {
        MaskRasterStore.shared.holdsRaster(for: mask.id)
    }

    /// Picks another of the things the machine found: the second person, the third subject.
    ///
    /// The mask takes a **new identity**, because the picture of the old one is filed under
    /// the old id and a layer with no picture is a layer that changes nothing — which is
    /// exactly the right thing to show while the new one is being looked for. What was
    /// painted on it by hand is carried over: the corrections were made to a shape, and the
    /// photographer asked for another shape, not for their work to be thrown away.
    public func chooseInstance(_ instance: Int, of mask: DetectedMask) {
        guard instance != mask.instance else { return }
        perform {
            updateSelectedMask(.detected(DetectedMask(
                subject: mask.subject, instance: instance,
                isInverted: mask.isInverted, corrections: mask.corrections
            )))
        }
        findMasks()
    }

    /// Asks Vision for every found mask of the open photo that has no picture yet, one after
    /// the other, off the main actor. Called when a photo opens and when a layer is added:
    /// a mask is found once and kept, since it depends on the photograph and not on the edit.
    ///
    /// Nothing here fails loudly. A photograph with nobody in it gives no mask, and the layer
    /// that asked for one goes on changing nothing — which is what it did while waiting.
    public func findMasks() {
        guard let url = source?.url else { return }
        let wanted = adjustments.locals.compactMap { local -> DetectedMask? in
            guard case .detected(let mask) = local.mask, !hasRaster(for: mask) else { return nil }
            return mask
        }
        guard !wanted.isEmpty, maskSearch == nil else { return }
        maskSearch = Task { [weak self] in
            defer { self?.maskSearch = nil }
            for mask in wanted {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Found once, not once per opening: twelve milliseconds a mask, plus the
                // model the first time in a launch, paid again every evening on the same
                // photograph. The id is in the document, so it outlives the session.
                if let kept = maskCache.raster(for: mask.id) {
                    MaskRasterStore.shared.store(kept, for: mask.id)
                    maskRevision += 1
                    continue
                }
                let raster = await maskFinder.mask(of: mask.subject, instance: mask.instance, in: url)
                let found = await maskFinder.count(of: mask.subject, in: url)
                guard !Task.isCancelled, source?.url == url else { return }
                detectedInstances[mask.subject] = found
                if let raster {
                    MaskRasterStore.shared.store(raster, for: mask.id)
                    maskCache.store(raster, for: mask.id)
                    // The canvas draws from `adjustments`; the raster it reads sits outside
                    // them, so it has to be told that the picture has changed.
                    maskRevision += 1
                }
            }
            // A second layer may have been added while the first was being found.
            self?.findMasks()
        }
    }

    /// Resolves once every mask asked for has been looked for. For tests and scripts.
    public func masksSettled() async {
        while let task = maskSearch { await task.value }
    }

    public func removeSelectedLocal() {
        if let selectedLocalID { removeLayer(selectedLocalID) }
    }

    // MARK: - Layers

    /// What the layers panel shows for one layer.
    public struct LayerSummary: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let kind: MaskKind
        public let isEnabled: Bool
        public let opacity: Double
    }

    /// The stack, top layer first: the way layers are always listed.
    public var layers: [LayerSummary] {
        let names = adjustments.locals.displayNames
        return zip(adjustments.locals, names).reversed().map { layer, name in
            LayerSummary(id: layer.id, name: name, kind: layer.mask.kind, isEnabled: layer.isEnabled, opacity: layer.opacity)
        }
    }

    public func setLayer(_ id: UUID, enabled: Bool) {
        perform { edit(id) { $0.isEnabled = enabled } }
    }

    /// Not a step of its own: opacity is dragged, and settles like any slider.
    public func setLayer(_ id: UUID, opacity: Double) {
        edit(id) { $0.opacity = min(max(opacity, 0), 100) }
    }

    /// A blank name goes back to the default one.
    public func renameLayer(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        perform { edit(id) { $0.name = trimmed.isEmpty ? nil : trimmed } }
    }

    public func removeLayer(_ id: UUID) {
        perform { adjustments.locals.removeAll { $0.id == id } }
        if selectedLocalID == id { selectedLocalID = nil }
    }

    /// "Up" is toward the top of the stack: applied later, over the others.
    public func moveLayer(_ id: UUID, up: Bool) {
        perform { adjustments.locals.moveLayer(withID: id, by: up ? 1 : -1) }
    }

    public func canMoveLayer(_ id: UUID, up: Bool) -> Bool {
        guard let index = adjustments.locals.firstIndex(where: { $0.id == id }) else { return false }
        return up ? index < adjustments.locals.count - 1 : index > 0
    }

    public func duplicateLayer(_ id: UUID) {
        var copy: LocalAdjustment?
        perform { copy = adjustments.locals.duplicateLayer(withID: id) }
        if let copy { selectedLocalID = copy.id }
    }

    // MARK: - Range of tones

    /// The tones the selected layer is held to. A layer on every tone reads as the whole
    /// scale: that is what the sliders show before the limit is turned on.
    public var selectedLuminanceRange: LuminanceRange {
        selectedLocal?.luminanceRange ?? LuminanceRange()
    }

    /// Whether the selected layer only shows on a range of tones. Turning it on starts on the
    /// bright half: the sky, which is what "the gradient that spares the steeple" is for.
    public var limitsSelectedLayerToTones: Bool {
        get { selectedLocal?.luminanceRange != nil }
        set {
            guard let id = selectedLocalID, newValue != limitsSelectedLayerToTones else { return }
            perform { edit(id) { $0.luminanceRange = newValue ? LuminanceRange(lower: 0.5, upper: 1) : nil } }
        }
    }

    /// Not a step of its own: the bounds are dragged, and settle like any slider.
    public func setSelectedLuminanceRange(_ range: LuminanceRange) {
        guard let id = selectedLocalID else { return }
        edit(id) { $0.luminanceRange = range.sanitized() }
    }

    /// How much of the layer shows on each tone, from black to white: the ramp drawn under
    /// the bounds, so that the softness is seen rather than guessed.
    public func luminanceRampSamples(count: Int = 64) -> [Double] {
        guard count > 1 else { return [] }
        let range = selectedLuminanceRange
        return (0..<count).map { range.value(at: Double($0) / Double(count - 1)) }
    }

    private func edit(_ id: UUID, _ change: (inout LocalAdjustment) -> Void) {
        guard let index = adjustments.locals.firstIndex(where: { $0.id == id }) else { return }
        change(&adjustments.locals[index])
    }

    /// Replaces the mask of the selected local adjustment: what overlay handles call.
    public func updateSelectedMask(_ mask: Mask) {
        guard let index = adjustments.locals.firstIndex(where: { $0.id == selectedLocalID }) else { return }
        isEditingMask = true
        adjustments.locals[index].mask = mask
    }

    // MARK: - Brush

    /// Closest two points of a stroke may be, in frame fractions: a drag reports far more
    /// positions than a smooth stroke needs.
    static let minimumStrokeSpacing = 0.004

    public func beginStroke(at point: NormalizedPoint) {
        guard var strokes = paintedStrokes else { return }
        commitEdit()
        strokes.strokes.append(.init(points: [point], radius: brushRadius, isErasing: isErasing))
        setPaintedStrokes(strokes)
    }

    public func continueStroke(to point: NormalizedPoint) {
        guard var strokes = paintedStrokes, let last = strokes.strokes.last?.points.last else { return }
        guard hypot(point.x - last.x, point.y - last.y) >= Self.minimumStrokeSpacing else { return }
        strokes.strokes[strokes.strokes.count - 1].points.append(point)
        setPaintedStrokes(strokes)
    }

    /// The strokes the brush is working on: a painted mask is all of them, a found one is the
    /// corrections made to what the machine found. The gesture is the same either way, which
    /// is the point — a mask that is nearly right is finished with the brush.
    private var paintedStrokes: BrushMask? {
        switch selectedLocal?.mask {
        case .brush(let mask): mask
        case .detected(let mask): mask.corrections
        default: nil
        }
    }

    private func setPaintedStrokes(_ strokes: BrushMask) {
        switch selectedLocal?.mask {
        case .brush:
            updateSelectedMask(.brush(strokes))
        case .detected(var mask):
            mask.corrections = strokes
            updateSelectedMask(.detected(mask))
        default:
            break
        }
    }

    /// Whether the brush can work on the selected layer.
    public var canPaintSelectedMask: Bool { paintedStrokes != nil }

    /// A stroke is one undo step, however many points it has.
    public func endStroke() {
        commitEdit()
    }

    // MARK: - Spots

    /// Default size of a new spot, in fractions of the long edge.
    static let defaultSpotRadius = 0.015

    /// Adds a spot whose source sits right next to it, on the side that has room.
    public func addSpot(at target: NormalizedPoint) {
        let spot = Spot(target: target, source: Self.sourceBeside(target), radius: Self.defaultSpotRadius)
        perform { adjustments.spots.append(spot) }
        selectedSpotID = spot.id
    }

    /// Right next to a point, on the side that has room.
    static func sourceBeside(_ target: NormalizedPoint) -> NormalizedPoint {
        let offset = defaultSpotRadius * 3
        return NormalizedPoint(x: target.x + (target.x + offset <= 1 ? offset : -offset), y: target.y)
    }

    /// Starts drawing a line along a blemish. The source sits beside the first point, as it
    /// does for a spot; where it sits is worth changing afterwards, and can be.
    ///
    /// Not a step of its own, unlike `addSpot`: the whole line is one, taken when the pointer
    /// comes up, exactly as a brush stroke is.
    public func beginHealingLine(at target: NormalizedPoint) {
        commitEdit()
        let spot = Spot(target: target, source: Self.sourceBeside(target), radius: Self.defaultSpotRadius)
        adjustments.spots.append(spot)
        selectedSpotID = spot.id
        healingLineID = spot.id
    }

    /// Carries the line on. Points closer together than a fraction of the radius are dropped:
    /// a drag reports far more of them than a stroke needs, and each one costs a disc.
    public func continueHealingLine(to point: NormalizedPoint) {
        guard let healingLineID, let index = adjustments.spots.firstIndex(where: { $0.id == healingLineID }) else { return }
        let spot = adjustments.spots[index]
        let last = spot.points[spot.points.count - 1]
        guard hypot(point.x - last.x, point.y - last.y) >= spot.radius * Self.healingLineStep else { return }
        adjustments.spots[index].path.append(point)
    }

    /// The line is finished. What was drawn settles like any other gesture.
    public func endHealingLine() {
        healingLineID = nil
        commitEdit()
    }

    /// How far the pointer must travel before the line takes another point, as a share of the
    /// brush radius. A quarter is smooth and keeps the count of discs down.
    static let healingLineStep = 0.25

    public func removeSelectedSpot() {
        perform { adjustments.spots.removeAll { $0.id == selectedSpotID } }
        selectedSpotID = nil
    }

    public func updateSpot(_ spot: Spot) {
        guard let index = adjustments.spots.firstIndex(where: { $0.id == spot.id }) else { return }
        adjustments.spots[index] = spot
    }

    // MARK: - Overlay

    /// The crop, when it can be drawn over the original frame the local tools show: that is,
    /// when the picture is neither turned nor straightened, which would tilt it.
    var cropShownByLocalTools: CropRect? {
        let geometry = adjustments.geometry
        guard geometry.quarterTurns == 0, geometry.straighten == 0 else { return nil }
        return geometry.crop
    }

    /// Whether the selected mask is laid over the picture, in red. No switch for it: the veil
    /// is there while it is the only thing that shows the mask (the layer does nothing yet,
    /// or the mask is being moved or painted), and gives way to the effect after that.
    public var showsMaskOverlay: Bool {
        guard tool == .local, let local = selectedLocal else { return false }
        return keepsMaskOverlay || isEditingMask || local.settings.isNeutral
    }

    /// `image` with the selected mask laid over it in red, the way masks are usually shown.
    func withMaskOverlay(_ image: CIImage) -> CIImage {
        guard showsMaskOverlay, let mask = selectedLocal?.mask else { return image }
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.45)).cropped(to: image.extent)
        return red.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask.image(in: image.extent),
        ]).cropped(to: image.extent)
    }
}

extension Adjustments {
    /// The settings of a local adjustment, by id. Reading a mask that is gone gives neutral
    /// settings and writing to it does nothing: a slider can outlive its mask by a frame.
    subscript(local id: UUID) -> LocalSettings {
        get { locals.first { $0.id == id }?.settings ?? LocalSettings() }
        set {
            guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
            locals[index].settings = newValue
        }
    }
}
