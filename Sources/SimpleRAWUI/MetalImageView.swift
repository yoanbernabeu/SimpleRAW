import CoreImage
import MetalKit
import SwiftUI

/// Displays a `CIImage` fitted in the view, rendered straight to a Metal drawable: the image
/// never leaves the GPU between the RAW decoder and the screen.
struct MetalImageView: NSViewRepresentable {
    /// Asked on every draw for the image to show, given the view size in pixels.
    let image: @MainActor (CGSize) -> CIImage?
    /// Changes whenever the image would: tells SwiftUI a redraw is due.
    let revision: AnyHashable
    /// Two-finger scrolling over the picture, in points: what moves the 100 % view.
    var onScroll: (@MainActor (CGSize) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        // Draw on demand only: nothing animates, a static image must cost nothing.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        // Core Image needs to write to the drawable, and half floats avoid banding.
        view.framebufferOnly = false
        view.colorPixelFormat = .rgba16Float
        (view.layer as? CAMetalLayer)?.colorspace = Coordinator.displayColorSpace
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.watchScroll(over: view, onScroll)
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.stopWatchingScroll()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        static let displayColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

        let device: MTLDevice?
        private let queue: MTLCommandQueue?
        private let context: CIContext?
        var image: (@MainActor (CGSize) -> CIImage?)?
        private var onScroll: (@MainActor (CGSize) -> Void)?
        private var scrollMonitor: Any?
        private weak var watchedView: NSView?

        override init() {
            device = MTLCreateSystemDefaultDevice()
            queue = device?.makeCommandQueue()
            context = queue.map {
                CIContext(mtlCommandQueue: $0, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
            }
        }

        /// Scrolling over the canvas, whatever sits above it: tool overlays are SwiftUI views
        /// laid over the Metal view, and would otherwise swallow the event or pass it on.
        func watchScroll(over view: NSView, _ onScroll: (@MainActor (CGSize) -> Void)?) {
            self.onScroll = onScroll
            watchedView = view
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let (location, windowNumber) = (event.locationInWindow, event.windowNumber)
                let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
                // Local monitors run on the main thread.
                let handled = MainActor.assumeIsolated {
                    guard let self, let onScroll = self.onScroll, let view = self.watchedView,
                          view.window?.windowNumber == windowNumber,
                          view.bounds.contains(view.convert(location, from: nil)) else { return false }
                    onScroll(delta)
                    return true
                }
                return handled ? nil : event
            }
        }

        func stopWatchingScroll() {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated { view.needsDisplay = true }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(in: view) }
        }

        private func render(in view: MTKView) {
            guard let context, let buffer = queue?.makeCommandBuffer(), let drawable = view.currentDrawable else {
                return
            }
            let bounds = CGRect(origin: .zero, size: view.drawableSize)
            let destination = CIRenderDestination(
                width: Int(bounds.width),
                height: Int(bounds.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: buffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.colorSpace = Self.displayColorSpace

            // The image is asked for at the size of the padded area, then placed by the same
            // rule the crop overlay uses, so that the two line up.
            let padding = FitGeometry.padding * (view.window?.backingScaleFactor ?? 2)
            let available = CGSize(width: bounds.width - 2 * padding, height: bounds.height - 2 * padding)
            var output = CIImage(color: Theme.canvasColor).cropped(to: bounds)
            if available.width > 0, available.height > 0, let image = image?(available) {
                let aspect = image.extent.width / image.extent.height
                let frame = FitGeometry.frame(forAspect: aspect, in: bounds.size, padding: padding)
                output = Self.placed(image, in: frame).composited(over: output)
            }

            _ = try? context.startTask(toRender: output, from: bounds, to: destination, at: .zero)
            buffer.present(drawable)
            buffer.commit()
        }

        /// Stretches `image` over `frame`, which is expected to have its aspect ratio.
        static func placed(_ image: CIImage, in frame: CGRect) -> CIImage {
            let extent = image.extent
            return image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: frame.width / extent.width, y: frame.height / extent.height))
                .transformed(by: CGAffineTransform(translationX: frame.minX.rounded(), y: frame.minY.rounded()))
        }
    }
}
