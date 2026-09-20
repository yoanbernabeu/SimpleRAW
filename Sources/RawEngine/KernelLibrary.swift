import Foundation

/// Where the compiled Core Image kernels are, whoever built this copy and however it was
/// wrapped — and, above all, what happens when they are nowhere.
///
/// SwiftPM writes an accessor for exactly this, `Bundle.module`, and it was used here until
/// an installed app died of it: the accessor knows three places and ends in `fatalError`
/// when the resource bundle is in none of them. Opening a photograph asks the inspector
/// which sliders to offer, the inspector asks whether this build can warp a picture, and a
/// bundle that did not arrive — an interrupted copy, a wrapper built elsewhere — took the
/// whole app down on the main thread, where a slider should simply not have been offered.
///
/// So the search is ours, it is pure, and its answer is an optional. It reads both layouts a
/// build may produce: the `Contents/Resources` one this machine's toolchain writes, and the
/// flat one — the library at the root of the bundle, no `Info.plist` — that the release
/// runner's wrote in the copy that crashed.
enum KernelLibrary {
    /// `<package>_<target>.bundle`, the name SwiftPM gives a target's resources.
    static let bundleName = "SimpleRAW_RawEngine"

    /// The library the `MetalKernels` plugin compiles, empty where there was no compiler.
    static let resourceName = "CoreImageKernels.metallib"

    /// The first library found in `folders`, or nothing at all.
    static func url(searching folders: [URL], fileManager: FileManager = .default) -> URL? {
        for folder in folders {
            let bundle = folder.appending(path: "\(bundleName).bundle")
            let layouts = [
                bundle.appending(path: "Contents/Resources/\(resourceName)"),
                bundle.appending(path: resourceName),
            ]
            if let found = layouts.first(where: { fileManager.fileExists(atPath: $0.path) }) {
                return found
            }
        }
        return nil
    }

    /// Beside this code first, then beside the executable: a test bundle, a bare command-line
    /// tool and an app wrapper each keep the resources in one of these, and a copy that keeps
    /// them somewhere else only loses a slider.
    static var searchedFolders: [URL] {
        let engine = Bundle(for: BundleToken.self)
        let main = Bundle.main
        let folders = [
            engine.resourceURL,
            engine.bundleURL.deletingLastPathComponent(),
            main.resourceURL,
            main.bundleURL,
            main.executableURL?.deletingLastPathComponent(),
        ].compactMap { $0 }
        var seen = Set<URL>()
        return folders.filter { seen.insert($0).inserted }
    }
}

/// Names the bundle this code was linked into, which is what `Bundle(for:)` answers.
private final class BundleToken {}
