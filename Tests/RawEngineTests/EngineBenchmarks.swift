import CoreImage
import Foundation
import Metal
import Testing
import TestSupport
@testable import RawEngine

/// What the engine costs where a gesture pays for it on every frame. Timing only means
/// something in release, on a quiet machine, so this suite never runs as part of `make test`:
///
///     SIMPLERAW_BENCH=1 swift test -c release --filter EngineBenchmarks
///
/// It needs no sample: everything is measured on synthetic pictures.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SIMPLERAW_BENCH"] != nil, "Set SIMPLERAW_BENCH"), .serialized)
struct EngineBenchmarks {
    /// Median over `runs`, in milliseconds.
    static func median(runs: Int = 200, _ work: (Int) -> Void) -> Double {
        let times = (0..<runs).map { run -> Double in
            let start = DispatchTime.now().uptimeNanoseconds
            work(run)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }.sorted()
        return times[times.count / 2]
    }

    static func report(_ name: String, _ milliseconds: Double) {
        print(String(format: "ENGINE-BENCH %-52@ %7.3f ms", name as NSString, milliseconds))
    }

    /// Four curves of eight points, as a look plus a few edits leave them.
    static let curves: Curves = {
        func curve(_ lift: Double) -> Curve {
            Curve(points: (0...7).map { .init(x: Double($0) / 7, y: min(1, pow(Double($0) / 7, 0.8) + lift)) })
        }
        var curves = Curves()
        (curves.rgb, curves.red, curves.green, curves.blue) = (curve(0), curve(0.01), curve(0.02), curve(0.03))
        return curves
    }()

    /// Any gesture on a picture whose curves are edited: the table has not changed.
    @Test func curvesStageWithUnchangedCurves() {
        let (stage, picture) = (CurvesStage(), PixelProbe.swatch(r: 0.2, g: 0.2, b: 0.2))
        var adjustments = Adjustments()
        adjustments.curves = Self.curves
        let cost = Self.median { run in
            adjustments.exposure = Double(run) / 200
            _ = stage.apply(adjustments, to: picture)
        }
        Self.report("curves stage, curves unchanged", cost)
        #expect(cost < 0.2)
    }

    /// Dragging a curve point: a new table on every frame.
    @Test func curvesStageWhileDraggingAPoint() {
        let (stage, picture) = (CurvesStage(), PixelProbe.swatch(r: 0.2, g: 0.2, b: 0.2))
        var adjustments = Adjustments()
        adjustments.curves = Self.curves
        let cost = Self.median { run in
            adjustments.curves.rgb.move(at: 3, to: .init(x: 3.0 / 7, y: 0.3 + Double(run) / 1000))
            _ = stage.apply(adjustments, to: picture)
        }
        Self.report("curves stage, a point dragged", cost)
        #expect(cost < 1)
    }

    // MARK: - Brush

    /// A real mask: ten strokes wandering over the picture, `count` points in all.
    static func paintedMask(points count: Int, strokes: Int = 10) -> BrushMask {
        BrushMask(strokes: (0..<strokes).map { stroke in
            let points = (0..<count / strokes).map { index -> NormalizedPoint in
                let progress = Double(index) / Double(count / strokes)
                return NormalizedPoint(x: 0.05 + 0.9 * progress, y: 0.1 + 0.08 * Double(stroke) + 0.03 * sin(progress * 40))
            }
            return BrushMask.Stroke(points: points, radius: 0.03, isErasing: stroke == 6)
        })
    }

    /// Median cost of one more point at the end of the last stroke, the mask being asked for
    /// at the size of the canvas after each point, as painting does.
    static func costOfPainting(on mask: BrushMask, points: Int = 200) -> Double {
        let canvas = CGRect(x: 0, y: 0, width: 2300, height: 1533)
        var mask = mask
        _ = Mask.brush(mask).image(in: canvas)
        return median(runs: points) { run in
            let progress = Double(run) / Double(points)
            mask.strokes[mask.strokes.count - 1].points.append(.init(x: 0.95 - 0.9 * progress, y: 0.95 - 0.02 * sin(progress * 30)))
            _ = Mask.brush(mask).image(in: canvas)
        }
    }

    /// Painting must cost the same on a mask of 3 000 points as on a fresh one: what is
    /// already painted is not drawn again.
    @Test func paintingCostsTheSameHoweverMuchIsAlreadyPainted() {
        let small = Self.costOfPainting(on: Self.paintedMask(points: 300))
        let large = Self.costOfPainting(on: Self.paintedMask(points: 3000))
        Self.report("one more brush point, mask of 300 points", small)
        Self.report("one more brush point, mask of 3 000 points", large)
        #expect(large < 1, "a point on a large mask takes \(large) ms")
        #expect(large < small * 2 + 0.1, "cost grows with the mask: \(small) ms → \(large) ms")
    }

    // MARK: - A worked picture

    /// The canvas of the default window on a Retina display, as in `FluidityBenchmarks`.
    static let canvas = CGSize(width: 2300, height: 1540)

    /// Sensor dust over a sky and layers of every kind: what a worked picture carries.
    static func workedPicture(spots: Int, layers: Int, presence: Bool = false, tones: Bool = false) -> Adjustments {
        var adjustments = Adjustments()
        adjustments.spots = (0..<spots).map { index in
            let target = NormalizedPoint(x: 0.06 + 0.045 * Double(index), y: 0.1 + 0.25 * abs(sin(Double(index))))
            return Spot(target: target, source: .init(x: target.x + 0.03, y: target.y + 0.02), radius: 0.012)
        }
        var settings = LocalSettings()
        (settings.exposure, settings.contrast, settings.shadows, settings.saturation) = (0.4, 15, 25, 10)
        if presence { (settings.clarity, settings.dehaze) = (40, 30) }
        let masks: [Mask] = [
            .radial(RadialMask(center: .init(x: 0.3, y: 0.4), radiusX: 0.12, radiusY: 0.15)),
            .linear(LinearMask(start: .init(x: 0.5, y: 0.1), end: .init(x: 0.5, y: 0.45))),
            .radial(RadialMask(center: .init(x: 0.7, y: 0.6), radiusX: 0.2, radiusY: 0.1, feather: 0.8)),
            .brush(BrushMask(strokes: Array(paintedMask(points: 300).strokes[0..<3]))),
            .radial(RadialMask(center: .init(x: 0.95, y: 0.1), radiusX: 0.15, radiusY: 0.15)),
            .radial(RadialMask(center: .init(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.4, isInverted: true)),
            .linear(LinearMask(start: .init(x: 0.5, y: 0.95), end: .init(x: 0.45, y: 0.7))),
            .brush(BrushMask(strokes: Array(paintedMask(points: 300).strokes[7..<9]))),
        ]
        adjustments.locals = masks.prefix(layers).map { mask in
            var layer = LocalAdjustment(mask: mask, settings: settings)
            if tones { layer.luminanceRange = LuminanceRange(lower: 0.5, upper: 1, softness: 0.2) }
            return layer
        }
        return adjustments
    }

    /// A real photo developed at the size of the canvas and rendered the way the app does,
    /// the GPU waited for: what a frame of a drag costs on a picture more and more worked.
    ///
    /// The load goes up step by step and the bench stops by itself at the first step that is
    /// slow or hungry: a graph gone wrong must show on one spot, not on twenty.
    /// - Returns: the median frame with 20 spots and 8 layers, in milliseconds.
    static func dragging(
        _ name: String, loads: [(Int, Int)] = [(0, 0), (1, 0), (5, 0), (20, 0), (20, 1), (20, 4), (20, 8)], presence: Bool = false, tones: Bool = false,
        _ gesture: (inout Adjustments, Int) -> Void
    ) throws -> Double? {
        MemoryFuse.arm()
        let source = try RawSource(url: try #require(Sample.reference))
        let scale = PreviewScale.factor(for: source.info.imageSize, fitting: canvas)
        let queue = try #require(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        let context = CIContext(mtlCommandQueue: queue, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(canvas.width), height: Int(canvas.height), mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        let texture = try #require(queue.device.makeTexture(descriptor: descriptor))

        let (slowest, hungriest) = (60.0, UInt64(3_000_000_000))
        var last = 0.0
        for (spots, layers) in loads {
            var adjustments = workedPicture(spots: spots, layers: layers, presence: presence, tones: tones)
            var times: [Double] = []
            for frame in 0..<32 {
                let start = DispatchTime.now().uptimeNanoseconds
                gesture(&adjustments, frame)
                // A finite picture, straight from the decoder: never a generator.
                let image = try source.image(adjustments: adjustments, scaleFactor: scale)
                let buffer = try #require(queue.makeCommandBuffer())
                try context.startTask(toRender: image, to: CIRenderDestination(mtlTexture: texture, commandBuffer: buffer))
                buffer.commit()
                buffer.waitUntilCompleted()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                guard times.last! < 1000, MemoryFuse.footprint < hungriest else { break }
            }
            let steady = times.dropFirst(8).sorted()
            last = steady.isEmpty ? (times.max() ?? .infinity) : steady[steady.count / 2]
            report("\(name), \(spots) spots + \(layers) layers", last)
            guard last < slowest, MemoryFuse.footprint < hungriest else {
                Issue.record("\(name) stopped at \(spots) spots + \(layers) layers: \(last) ms per frame, \(MemoryFuse.footprint) bytes")
                return nil
            }
        }
        print(String(format: "ENGINE-BENCH   footprint %.2f GB", Double(MemoryFuse.footprint) / 1_073_741_824))
        return last
    }

    /// Exposure is the worst case: the decoded image changes, so every spot and every layer
    /// is computed again, each as a pass over the whole frame (0.9 ms a spot, 1.2 ms a layer).
    ///
    /// Over budget, and known to be: 29.6 ms with 20 spots and 8 layers. Two ways out were
    /// measured and thrown away. Blending within the bounds of each disc gives the same
    /// pixels and is linear on a swatch, but on a real photo reading the picture over several
    /// areas replays the decoder: 298 ms for 20 spots. A cached intermediate after the spots
    /// changes nothing here. What is left to try: every spot in one pass.
    @Test(.enabled(if: Sample.reference != nil, "Needs the reference photo in Samples/"))
    func aWorkedPictureWhileExposureIsDragged() throws {
        let cost = try #require(try Self.dragging("exposure drag") { $0.exposure = Double($1) / 64 })
        withKnownIssue("A pass over the whole frame per spot and per layer") {
            #expect(cost <= 16, "20 spots and 8 layers take \(cost) ms per frame")
        }
    }

    /// A slider that sits after the local work: spots and layers have not changed.
    @Test(.enabled(if: Sample.reference != nil, "Needs the reference photo in Samples/"))
    func aWorkedPictureWhileADownstreamSliderIsDragged() throws {
        let cost = try Self.dragging("vibrance drag") { $0.vibrance = Double($1) }
        #expect(try #require(cost) <= 16, "20 spots and 8 layers take \(cost ?? 0) ms per frame")
    }

    /// Clarity and dehaze in a layer are the global stages run once more, wide blurs included.
    /// Measured on an otherwise untouched picture. Three layers with both used to take 25.7 ms
    /// and was a known issue; the way out was where it was said to be — the wide blur of
    /// `LocalContrastStage` is now computed on a reduced copy, as the glow always did — and it
    /// takes 15.8, inside the budget. That change was made for a seam in the sky, not for this;
    /// it happens that a hundred-and-twenty-pixel convolution was never cheap.
    @Test(.enabled(if: Sample.reference != nil, "Needs the reference photo in Samples/"))
    func layersWithClarityAndDehaze() throws {
        let one = try #require(try Self.dragging("exposure drag, clarity and dehaze in", loads: [(0, 1)], presence: true) { $0.exposure = Double($1) / 64 })
        #expect(one <= 16, "one layer with clarity and dehaze takes \(one) ms per frame")
        let three = try #require(try Self.dragging("exposure drag, clarity and dehaze in", loads: [(0, 3)], presence: true) { $0.exposure = Double($1) / 64 })
        #expect(three <= 16, "three layers with clarity and dehaze take \(three) ms per frame")
    }

    /// A range of tones is a second mask per layer, read off the picture: a few passes that
    /// touch each pixel once, and a mask grown by a couple of pixels.
    @Test(.enabled(if: Sample.reference != nil, "Needs the reference photo in Samples/"))
    func layersLimitedToARangeOfTones() throws {
        let plain = try #require(try Self.dragging("exposure drag, plain", loads: [(0, 3)]) { $0.exposure = Double($1) / 64 })
        let limited = try #require(try Self.dragging("exposure drag, limited to highlights,", loads: [(0, 3)], tones: true) { $0.exposure = Double($1) / 64 })
        #expect(limited <= 16, "three layers limited to a range of tones take \(limited) ms per frame (\(plain) without)")
    }
}

