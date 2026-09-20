import CoreImage
import Foundation
import Metal
import RawEngine
import TestSupport
import Testing
@testable import SimpleRAWUI

/// Fluidity is a requirement, so it is measured: every continuous gesture is replayed and
/// must stay within the frame budget. Timing only means something in release, on a quiet
/// machine: this suite runs through `make bench`, never as part of `make test`.
///
/// Always on the **reference** photograph, never on whatever sorts first in `Samples/`: a
/// number is only worth writing down if the next one measures the same thing. A smaller file
/// dropped into the folder would quietly halve every figure here.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SIMPLERAW_BENCH"] != nil && Sample.reference != nil, "Run `make bench`"), .serialized)
struct FluidityBenchmarks {
    /// 60 frames per second.
    static let budget = 16.0
    /// The canvas of the default window on a Retina display, in pixels.
    static let canvas = CGSize(width: 2300, height: 1540)

    let session = DevelopSession()
    let queue: MTLCommandQueue
    let context: CIContext
    let texture: MTLTexture

    init() throws {
        session.open(try #require(Sample.reference))
        queue = try #require(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        // Same options as the on-screen view.
        context = CIContext(mtlCommandQueue: queue, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(Self.canvas.width), height: Int(Self.canvas.height), mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        texture = try #require(queue.device.makeTexture(descriptor: descriptor))
    }

    /// What a gesture cost, frame by frame, once shaders are compiled and caches warm.
    struct Timing {
        let median, p95, max: Double

        init(steadyFrames: [Double]) {
            let sorted = steadyFrames.sorted()
            median = sorted[sorted.count / 2]
            p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            max = sorted[sorted.count - 1]
        }
    }

    /// A stutter is a slow frame, not a slow average: the 95th percentile may not stray far
    /// from the budget. The maximum is printed, not enforced: one frame in sixty that the
    /// system took for itself says nothing of the app.
    static let p95Budget = 18.0

    /// Replays a gesture: each frame changes something and renders the canvas the way the app
    /// does, while the histogram is recomputed in the background, as in the app, competing
    /// for the same GPU.
    private func median(frames: Int = 60, _ gesture: (Int) -> Void) throws -> Timing {
        var times: [Double] = []
        for frame in 0..<frames {
            // A pool per frame, as the run loop gives the app: Core Image hands back buffers
            // through autorelease, and a frame that renders a whole picture into one holds
            // hundreds of megabytes. Without this the loop, and only the loop, runs out.
            try autoreleasepool {
                let start = Date()
                gesture(frame)
                let image = try #require(session.previewImage(fitting: Self.canvas))
                let buffer = try #require(queue.makeCommandBuffer())
                try context.startTask(toRender: image, to: CIRenderDestination(mtlTexture: texture, commandBuffer: buffer))
                buffer.commit()
                buffer.waitUntilCompleted()
                times.append(Date().timeIntervalSince(start) * 1000)
            }
        }
        // The first frames compile shaders and warm caches: a user feels the steady state.
        return Timing(steadyFrames: Array(times.dropFirst(8)))
    }

    private func check(_ name: String, _ timing: Timing) {
        print(String(
            format: "BENCH %-46@ %5.1f ms  p95 %5.1f  max %5.1f  (budget %.0f, p95 %.0f)",
            name as NSString, timing.median, timing.p95, timing.max, Self.budget, Self.p95Budget
        ))
        #expect(timing.median <= Self.budget, "\(name) takes \(timing.median) ms")
        #expect(timing.p95 <= Self.p95Budget, "\(name) stutters: 95th percentile at \(timing.p95) ms")
    }

    @Test func draggingAGlobalSlider() throws {
        check("global slider, untouched picture", try median { session.adjustments.exposure = Double($0) / 60 })
    }

    @Test func draggingASliderOnAHeavilyEditedPicture() throws {
        session.adjustments.enhance = 40
        session.adjustments.clarity = 30
        session.adjustments.structure = 20
        session.adjustments.dehaze = 25
        session.adjustments.glow = 15
        session.adjustments.grain = 20
        session.adjustments.vignetting = 30
        session.adjustments.aberration = ChromaticAberration(redCyan: 40, blueYellow: -30)
        // Left out of the measurement by a build with no Metal compiler, like the slider.
        session.adjustments.distortion = 60
        session.adjustments.curves.rgb.insert(.init(x: 0.5, y: 0.56))
        session.adjustments.hsl[.blue].saturation = -20
        session.adjustments.grading[.shadows] = ColorWheel(hue: 210, saturation: 30)
        check("global slider, every tool in use", try median { session.adjustments.contrast = Double($0) / 2 })
    }

    /// Keystone correction on a plain picture. The median is now 8 ms, down from 26: the
    /// preview holds the scale it started the gesture with (`PreviewScale.held`) instead of
    /// decoding the RAW again every time the frame changes size. What is left is a stutter
    /// every so often — the 95th percentile is still around 40 ms — and it is **not** the
    /// scale: widening the tolerance to half changes the timings not at all. The remaining
    /// suspect is the homography's own cache, which Core Image fills with a new set of
    /// intermediates for every angle. Known issue.
    @Test func draggingTheTiltSlider() throws {
        withKnownIssue("the homography stutters every so often, though no longer on the decode") {
            check("keystone slider", try median(frames: 120) { frame in
                session.adjustments.geometry.perspective.vertical = Double(frame) / 2
            })
        }
    }

    /// The same drag on a worked picture: 16 ms, down from 26, which is the budget itself
    /// rather than comfortably inside it. Correct, not yet fluid.
    @Test func draggingTheTiltSliderOnAHeavilyEditedPicture() throws {
        session.adjustments.enhance = 40
        session.adjustments.clarity = 30
        session.adjustments.dehaze = 25
        session.adjustments.grain = 20
        session.adjustments.geometry.straighten = 2
        withKnownIssue("the homography on a worked picture sits on the budget, and stutters") {
            check("keystone slider, on a worked picture", try median(frames: 120) { frame in
                session.adjustments.geometry.perspective.vertical = Double(frame) / 2
            })
        }
    }

    @Test func draggingAnHSLSlider() throws {
        check("HSL slider (lookup table rebuilt every frame)", try median { session.adjustments.hsl[.blue].saturation = Double($0) - 30 })
    }

    @Test func draggingACurvePoint() throws {
        session.adjustments.curves.rgb.insert(.init(x: 0.5, y: 0.5))
        check("curve point", try median { session.adjustments.curves.rgb.move(at: 1, to: .init(x: 0.5, y: 0.4 + Double($0) / 300)) })
    }

    @Test func workingWithLayers() throws {
        session.addLocal(.linear)
        session.adjustments.locals[0].settings.exposure = -1
        session.addLocal(.radial)
        session.adjustments.locals[1].settings.exposure = 0.8
        session.adjustments.spots = [Spot(target: .init(x: 0.8, y: 0.3), source: .init(x: 0.85, y: 0.3), radius: 0.02)]
        check("moving a radial mask, two layers and a spot", try median { frame in
            if case .radial(var mask) = session.adjustments.locals[1].mask {
                mask.center.x = 0.3 + Double(frame) / 200
                session.adjustments.locals[1].mask = .radial(mask)
            }
        })
    }

    @Test func painting() throws {
        session.addLocal(.brush)
        session.adjustments.locals[0].settings.exposure = 1
        session.beginStroke(at: .init(x: 0.1, y: 0.5))
        check("painting a long brush stroke", try median(frames: 160) { frame in
            session.continueStroke(to: .init(x: 0.1 + Double(frame) * 0.005, y: 0.5 + 0.2 * sin(Double(frame) / 8)))
        })
    }

    /// Drawing along a wire: every few pixels the line takes another disc, and the whole
    /// stroke is healed again on the frame after.
    @Test func drawingAHealingLine() throws {
        session.tool = .spots
        session.beginHealingLine(at: .init(x: 0.1, y: 0.4))
        check("drawing a healing line", try median(frames: 120) { frame in
            session.continueHealingLine(to: .init(x: 0.1 + Double(frame) * 0.006, y: 0.4 + 0.02 * sin(Double(frame) / 10)))
        })
        session.endHealingLine()
    }

    /// A dust spot or the edge of a face is painted at 100 %, since zooming works in the tools.
    @Test func paintingAtFullSize() throws {
        session.addLocal(.brush)
        session.adjustments.locals[0].settings.exposure = 1
        session.zoomToActualSize(at: CGPoint(x: 0.4, y: 0.5))
        session.beginStroke(at: .init(x: 0.38, y: 0.5))
        check("painting at 100 %", try median(frames: 120) { frame in
            session.continueStroke(to: .init(x: 0.38 + Double(frame) * 0.0006, y: 0.5 + 0.01 * sin(Double(frame) / 8)))
        })
    }

    @Test func panningAtFullSize() async throws {
        session.toggleZoom(at: CGPoint(x: 0.3, y: 0.3))
        _ = session.previewImage(fitting: Self.canvas)
        // A user zooms in, looks, then pans: by then the full-size picture is ready.
        await session.zoomCacheSettled()
        check("panning at 100 %", try median { _ in session.pan(by: CGSize(width: 0.004, height: 0.002)) })
    }

    @Test func draggingASliderAtFullSize() throws {
        session.toggleZoom(at: CGPoint(x: 0.3, y: 0.3))
        check("global slider at 100 %", try median { session.adjustments.exposure = Double($0) / 60 })
    }
}
