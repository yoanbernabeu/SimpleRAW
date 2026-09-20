import AppKit
import Catalog
import ImageIO
import Observation
import RawEngine

/// What one cell of the grid shows. Each cell observes its own slot and nothing else, so a
/// thumbnail that arrives redraws one cell, not the grid.
@MainActor
@Observable
final class ThumbnailSlot {
    fileprivate(set) var image: CGImage?
    /// The thumbnail could not be made: the original is missing or unreadable.
    fileprivate(set) var hasFailed = false
    /// The fingerprint of the edits `image`, or the failure, was made from.
    @ObservationIgnored fileprivate var edits: String?
    @ObservationIgnored fileprivate var pixelSize = 0
}

/// Feeds the grid with thumbnails without ever blocking it. A cell asks when it appears and
/// says when it leaves; whether the file exists, rendering, reading and decoding all happen
/// off the main actor, a few photos at a time, in the order they were asked for.
@MainActor
final class ThumbnailLoader {
    /// Makes the thumbnail of a photo, no larger than asked; `nil` if it cannot be made.
    typealias Load = @Sendable (_ photo: Photo, _ maxPixelSize: Int) -> CGImage?

    /// Set while the develop view is on screen: the GPU is for the picture being edited.
    var isSuspended = false { didSet { startNext() } }
    /// The long edge thumbnails are decoded at: what the cells of the grid need, in pixels.
    var pixelSize = ThumbnailStore.defaultLongEdge

    private var slots: [Int64: ThumbnailSlot] = [:]
    /// Cells on screen, as far as they said.
    private var visible: Set<Int64> = []
    private var waiting: RequestQueue<Int64, Photo>
    private var inFlight: Set<Int64> = []
    /// Asked again while their load was running: the photo was edited in the meantime.
    private var askedAgain: [Int64: Photo] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Decoded images, evicted little by little and under memory pressure.
    private let cache = NSCache<NSNumber, CachedThumbnail>()
    private let concurrency: Int
    private let load: Load
    /// Clearing what older versions left in the previews folder. Kept for tests to wait on.
    private(set) var housekeeping: Task<Void, Never>?

    /// - Parameters:
    ///   - concurrency: loads at once. More would not go faster: they share the GPU, and the
    ///     grid must stay responsive while they run.
    ///   - queueLimit: about two screens of cells; older requests are forgotten.
    ///   - memoryLimit: bytes of decoded images kept; the rest is one disk read away.
    init(concurrency: Int = 3, queueLimit: Int = 240, memoryLimit: Int = 256 << 20, load: @escaping Load) {
        self.concurrency = concurrency
        self.load = load
        waiting = RequestQueue(limit: queueLimit)
        cache.totalCostLimit = memoryLimit
    }

    convenience init(library: Library) {
        let store = ThumbnailStore(directory: library.previews)
        self.init { photo, maxPixelSize in
            guard let url = try? store.thumbnail(for: photo, original: library.url(for: photo)) else { return nil }
            return Self.decode(url, maxPixelSize: maxPixelSize)
        }
        housekeeping = Task.detached(priority: .background) { store.removeLegacyThumbnails() }
    }

    /// What tells the thumbnail of a photo from the one it had before an edit. Read from the
    /// row of the catalog: nothing is decoded, encoded or hashed to draw a cell.
    static func key(for photo: Photo) -> String {
        (try? photo.adjustmentsFingerprint) ?? "unreadable"
    }

    /// What the cell of this photo observes. Costs a dictionary lookup: nothing is read,
    /// encoded or hashed here.
    func slot(for photo: Photo) -> ThumbnailSlot {
        let slot = slots[photo.id] ?? ThumbnailSlot()
        slots[photo.id] = slot
        if slot.image == nil { fill(slot, id: photo.id) }
        return slot
    }

    /// The thumbnail in memory, if there is one: what the loupe shows while it reads its own.
    func cachedImage(for id: Int64) -> CGImage? {
        cache.object(forKey: NSNumber(value: id))?.image
    }

    /// The cell of this photo is on screen. A photo edited since its thumbnail was made keeps
    /// showing the old one until the new one is ready.
    func request(_ photo: Photo) {
        let slot = slot(for: photo)
        visible.insert(photo.id)
        guard slot.edits != Self.key(for: photo) || (slot.pixelSize < pixelSize && !slot.hasFailed) else { return }
        if inFlight.contains(photo.id) {
            askedAgain[photo.id] = photo
        } else {
            waiting.push(photo, for: photo.id)
            startNext()
        }
    }

    /// The cell left the screen: its turn is given up, and it lets go of its image, which
    /// stays in memory for a while should the cell come back.
    func cancel(_ id: Int64) {
        visible.remove(id)
        waiting.remove(id)
        askedAgain[id] = nil
        guard let slot = slots[id], slot.image != nil else { return }
        slot.image = nil
        slot.edits = nil
    }

    /// Returns once nothing is loading and nothing can start. For tests.
    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private var isIdle: Bool { inFlight.isEmpty && (isSuspended || waiting.isEmpty) }

    private func fill(_ slot: ThumbnailSlot, id: Int64) {
        guard let cached = cache.object(forKey: NSNumber(value: id)) else { return }
        slot.image = cached.image
        slot.edits = cached.edits
        slot.pixelSize = cached.pixelSize
    }

    private func startNext() {
        while !isSuspended, inFlight.count < concurrency, let photo = waiting.pop() {
            inFlight.insert(photo.id)
            let (load, pixelSize) = (load, pixelSize)
            Task.detached(priority: .utility) { [weak self] in
                let image = load(photo, pixelSize)
                await self?.finish(photo, pixelSize: pixelSize, image)
            }
        }
        if isIdle {
            idleWaiters.forEach { $0.resume() }
            idleWaiters = []
        }
    }

    private func finish(_ photo: Photo, pixelSize: Int, _ image: CGImage?) {
        inFlight.remove(photo.id)
        if let image {
            let cached = CachedThumbnail(image: image, edits: Self.key(for: photo), pixelSize: pixelSize)
            cache.setObject(cached, forKey: NSNumber(value: photo.id), cost: image.bytesPerRow * image.height)
        }
        // A failure is remembered even for a cell that left: it must not be tried again each
        // time the cell comes back. An image only goes to a cell that is there to show it.
        if let slot = slots[photo.id], image == nil || visible.contains(photo.id) {
            if let image { slot.image = image }
            slot.hasFailed = image == nil
            slot.edits = Self.key(for: photo)
            slot.pixelSize = pixelSize
        }
        if let again = askedAgain.removeValue(forKey: photo.id) { request(again) }
        startNext()
    }

    /// The size to decode at for cells this wide: the next step up, so that dragging the size
    /// slider does not reload the grid at every point, and no more than what is stored. A cell
    /// stretches up to 1.4 times its minimum width to fill the row.
    nonisolated static func pixelSize(forCellWidth width: Double, displayScale: Double) -> Int {
        let needed = Int((width * 1.4 * displayScale).rounded(.up))
        return [256, 384].first { $0 >= needed } ?? ThumbnailStore.defaultLongEdge
    }

    /// Decoded here, fully and at the size asked, so that drawing the cell later costs
    /// nothing: a JPEG decodes faster and smaller at a fraction of its size.
    nonisolated static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private final class CachedThumbnail {
    let image: CGImage
    let edits: String
    let pixelSize: Int

    init(image: CGImage, edits: String, pixelSize: Int) {
        self.image = image
        self.edits = edits
        self.pixelSize = pixelSize
    }
}
