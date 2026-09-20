import CoreGraphics
import Foundation

/// Draws a brush mask into a bitmap it keeps, so that painting only ever draws what is new.
///
/// A stroke is drawn as a dot, then one capsule per segment, each on its own: a whole mask is
/// then nothing but the same calls made from a blank bitmap, which is what makes painting
/// point by point and drawing it all at once give the same pixels. Stroking the polyline as
/// one path instead cost a frame and more per point on a real mask (43 ms at 3 000 points),
/// because its outline overlaps itself all along.
final class BrushRasterizer: @unchecked Sendable {
    let size: CGSize

    private let lock = NSLock()
    private let context: CGContext?
    /// What the bitmap shows.
    private var drawn = BrushMask()
    /// The bitmap as an image, until something is drawn over it: asking again for the same
    /// mask hands out the same image, which Core Image need not upload again.
    private var snapshot: CGImage?
    private var counters = (fullDraws: 0, pointsDrawn: 0)

    /// How many times the bitmap was started over, and how many points were drawn since the
    /// last time: what tests read to know that painting stays incremental.
    var fullDraws: Int { lock.withLock { counters.fullDraws } }
    var pointsDrawn: Int { lock.withLock { counters.pointsDrawn } }

    init(size: CGSize) {
        self.size = size
        context = CGContext(
            data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        context?.setLineCap(.round)
        context?.setLineJoin(.round)
    }

    /// The mask, white where it was painted, hard-edged: softness comes from a blur, later.
    func bitmap(for mask: BrushMask) -> CGImage? {
        lock.withLock {
            guard let context else { return nil }
            if mask != drawn {
                if !Self.isPainting(mask, over: drawn) { startOver(in: context) }
                paint(mask, in: context)
            }
            if snapshot == nil { snapshot = context.makeImage() }
            return snapshot
        }
    }

    /// How many points of `mask` are on the bitmap already, if it can be reached by painting
    /// on: what the store picks a rasterizer on. `nil` when the bitmap shows something else,
    /// or when someone is drawing on it right now, whom nobody should wait for.
    func progress(toward mask: BrushMask) -> Int? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        guard mask == drawn || Self.isPainting(mask, over: drawn) else { return nil }
        return drawn.strokes.reduce(0) { $0 + $1.points.count }
    }

    /// Whether `mask` is `drawn` plus points at the end of its last stroke, plus new strokes.
    static func isPainting(_ mask: BrushMask, over drawn: BrushMask) -> Bool {
        guard let last = drawn.strokes.last else { return true }
        let index = drawn.strokes.count - 1
        guard mask.strokes.count > index, mask.strokes[..<index] == drawn.strokes[..<index] else { return false }
        let continued = mask.strokes[index]
        return continued.radius == last.radius && continued.isErasing == last.isErasing
            && continued.points.count >= last.points.count
            && continued.points[..<last.points.count] == last.points[...]
    }

    private func startOver(in context: CGContext) {
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        drawn = BrushMask()
        counters = (counters.fullDraws + 1, 0)
        snapshot = nil
    }

    /// Draws what `mask` has that the bitmap has not. `mask` must be painted over `drawn`.
    private func paint(_ mask: BrushMask, in context: CGContext) {
        if counters.fullDraws == 0 { startOver(in: context) }
        let bounds = CGRect(origin: .zero, size: size)
        let longEdge = max(size.width, size.height)
        for (index, stroke) in mask.strokes.enumerated().dropFirst(max(drawn.strokes.count - 1, 0)) {
            let already = index < drawn.strokes.count ? drawn.strokes[index].points.count : 0
            guard stroke.points.count > already else { continue }
            context.setStrokeColor(gray: stroke.isErasing ? 0 : 1, alpha: 1)
            context.setLineWidth(2 * stroke.radius * longEdge)
            for position in already..<stroke.points.count {
                let point = stroke.points[position].location(in: bounds)
                // A stroke starts as a dot, thanks to the round caps, then grows by segments.
                context.move(to: position == 0 ? point : stroke.points[position - 1].location(in: bounds))
                context.addLine(to: point)
                context.strokePath()
            }
            counters.pointsDrawn += stroke.points.count - already
        }
        drawn = mask
        snapshot = nil
    }
}

/// The rasters of the masks in use. A raster has one size whatever size the mask is asked
/// for, so that the canvas and the histogram, which want the same mask at two sizes on every
/// frame, share it; and a mask being painted finds the raster it was painted on so far.
final class BrushRasterStore: @unchecked Sendable {
    static let shared = BrushRasterStore()

    /// Two frames this close in aspect ratio are the same picture at two sizes: rounding a
    /// size to whole pixels moves its aspect ratio by a fraction of a percent.
    static let aspectTolerance = 0.01

    private let lock = NSLock()
    private let capacity: Int
    /// Least recently used first.
    private var entries: [BrushRasterizer] = []

    var rasterizers: [BrushRasterizer] { lock.withLock { entries } }

    /// A few rasters: a picture can carry several brushes, and thumbnails and exports of
    /// other pictures go through here too. 2.8 MB each.
    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    func raster(for mask: BrushMask, aspectRatio: Double) -> (bitmap: CGImage, size: CGSize)? {
        let rasterizer = rasterizer(for: mask, aspectRatio: aspectRatio)
        return rasterizer.bitmap(for: mask).map { ($0, rasterizer.size) }
    }

    /// The raster furthest along the way to `mask`, else a new one: a mask that is not what
    /// a raster shows plus some paint (an undo, or a reader lagging a few points behind) never
    /// takes over the raster somebody is painting on.
    private func rasterizer(for mask: BrushMask, aspectRatio: Double) -> BrushRasterizer {
        let candidates = lock.withLock { entries }.filter {
            abs(Double($0.size.width / $0.size.height) / aspectRatio - 1) < Self.aspectTolerance
        }
        let best = candidates
            .compactMap { candidate in candidate.progress(toward: mask).map { (candidate, $0) } }
            .max { $0.1 < $1.1 }?.0
        let chosen = best ?? BrushRasterizer(size: Self.rasterSize(aspectRatio: aspectRatio))
        lock.withLock {
            entries.removeAll { $0 === chosen }
            entries.append(chosen)
            if entries.count > capacity { entries.removeFirst() }
        }
        return chosen
    }

    /// The long edge is always `BrushMask.maximumRasterSide`: the size asked for plays no part.
    static func rasterSize(aspectRatio: Double) -> CGSize {
        let side = BrushMask.maximumRasterSide
        return aspectRatio >= 1
            ? CGSize(width: side, height: max(1, (side / aspectRatio).rounded()))
            : CGSize(width: max(1, (side * aspectRatio).rounded()), height: side)
    }
}
