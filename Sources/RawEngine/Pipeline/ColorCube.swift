import CoreImage
import CoreImage.CIFilterBuiltins
import Dispatch

/// Bakes a pure RGB → RGB function into a 3D lookup table the GPU can apply, evaluated on
/// display-referred (sRGB-encoded) values. This is how per-pixel color work that stock
/// filters do not cover gets done without custom kernels.
struct ColorCube {
    /// 32³ nodes: smooth color transforms are indistinguishable from the exact function.
    static let dimension = 32

    let data: Data

    /// Slices of the cube are independent, so they are computed in parallel: a cube is
    /// rebuilt on every frame while its sliders are dragged.
    init(_ transform: @Sendable (SIMD3<Float>) -> SIMD3<Float>) {
        let size = Self.dimension
        let scale = 1 / Float(size - 1)
        var values = [Float](repeating: 1, count: size * size * size * 4)
        values.withUnsafeMutableBufferPointer { buffer in
            // Each iteration writes its own slice only.
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: size) { blue in
                // Core Image expects red to vary fastest, then green, then blue.
                var offset = blue * size * size * 4
                for green in 0..<size {
                    for red in 0..<size {
                        let output = transform(SIMD3(Float(red), Float(green), Float(blue)) * scale)
                        buffer[offset] = output.x
                        buffer[offset + 1] = output.y
                        buffer[offset + 2] = output.z
                        offset += 4
                    }
                }
            }
        }
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func apply(to image: CIImage) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(Self.dimension)
        filter.cubeData = data
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // Highlights beyond display white must not be crushed onto the last node.
        filter.extrapolate = true
        return filter.outputImage ?? image
    }
}

/// Remembers the last few values built. Every frame of a slider drag runs the whole
/// pipeline, and rebuilding a lookup table or a painted mask whose inputs did not change
/// would waste most of the frame budget.
///
/// Stages are shared by everything that develops a picture (`DevelopPipeline.standard`): the
/// canvas on the main thread, thumbnails and exports in the background. Hence the two rules
/// below: room for a few values, so that a thumbnail does not evict what the canvas needs on
/// its next frame; and values built outside of the lock, so that the main thread never waits
/// for a background build that has nothing to do with it.
final class RecentValuesCache<Key: Equatable & Sendable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    /// Least recently used first.
    private var entries: [(key: Key, value: Value)] = []

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    func value(for key: Key, build: () -> Value) -> Value {
        if let cached = lock.withLock({ touch(key) }) { return cached }
        // Two threads missing the same key both build it: wasteful once, but never blocking.
        let built = build()
        return lock.withLock {
            // Whoever stored it first wins, so that every caller shares one value.
            if let cached = touch(key) { return cached }
            entries.append((key, built))
            if entries.count > capacity { entries.removeFirst() }
            return built
        }
    }

    /// The cached value, marked as the most recently used. Call with the lock held.
    private func touch(_ key: Key) -> Value? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.value
    }
}
