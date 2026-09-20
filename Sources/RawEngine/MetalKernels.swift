import CoreImage
import Foundation

/// The Core Image kernels compiled from `Sources/RawEngine/Kernels`, when the build had a
/// Metal compiler to compile them with.
///
/// Nearly everything in this engine is a stock filter or a lookup table built from a pure
/// Swift function, on purpose: `swift build` then works with the Command Line Tools alone.
/// Geometric distortion is the one treatment that cannot be written that way — it moves each
/// pixel by an amount that depends on where it is, and no stock filter takes a field of
/// displacements. So it has a kernel, and the kernel is **optional**: a build without
/// Xcode's Metal toolchain produces no library, `isAvailable` is false, the stage leaves the
/// picture alone and the interface does not offer what it cannot do.
public enum MetalKernels {
    /// The compiled library, or `nil` where the build had no compiler. Empty is the same as
    /// missing: that is what the build script writes when it finds no `metal`.
    private static let library: Data? = {
        guard let url = Bundle.module.url(forResource: "CoreImageKernels", withExtension: "metallib"),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }()

    /// Whether this build can warp a picture. Read by the inspector: a slider that does
    /// nothing is worse than no slider.
    public static var isAvailable: Bool { library != nil }

    /// A warp kernel by the name of its function, made once and kept: building one parses the
    /// library, which is not something to do on every frame of a drag.
    static func warp(_ name: String) -> CIWarpKernel? {
        warps.withLock { cache in
            if let kernel = cache[name] { return kernel }
            guard let library else { return nil }
            let kernel = try? CIWarpKernel(functionName: name, fromMetalLibraryData: library)
            cache[name] = kernel
            return kernel
        }
    }

    /// `.some(nil)` for a name the library does not hold: asked once, not on every frame.
    private static let warps = Mutex<[String: CIWarpKernel?]>([:])
}

/// The smallest lock that will do, so that a kernel can be shared by the canvas, the
/// thumbnails and an export at once.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
