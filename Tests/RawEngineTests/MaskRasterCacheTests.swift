import CoreImage
import Foundation
import TestSupport
import Testing
@testable import RawEngine

/// Keeping what the machine found, so that it is found once rather than once per opening.
@Suite struct MaskRasterCacheTests {
    private func folder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    private let grey = PixelProbe.swatch(r: 0.5, g: 0.5, b: 0.5, size: CGSize(width: 32, height: 32))

    @Test func nothingIsRememberedAtFirst() {
        #expect(MaskRasterCache(folder: folder()).raster(for: UUID()) == nil)
    }

    @Test func aMaskComesBackAsItWasPutIn() throws {
        let cache = MaskRasterCache(folder: folder())
        let id = UUID()
        cache.store(grey, for: id)

        let back = try #require(cache.raster(for: id))
        let probe = PixelProbe()
        #expect(try abs(probe.average(of: back).luminance - probe.average(of: grey).luminance) < 0.02)
        #expect(back.extent.width == 32)
    }

    /// The whole point of the version: a mask rendered differently must not be shown as if it
    /// were the current one.
    @Test func whatAnotherVersionWroteIsNotRead() throws {
        let place = folder()
        let cache = MaskRasterCache(folder: place)
        let id = UUID()
        cache.store(grey, for: id)

        let stale = place.appendingPathComponent("\(id.uuidString)-v0.png")
        try FileManager.default.moveItem(at: cache.file(for: id), to: stale)
        #expect(cache.raster(for: id) == nil)
    }

    @Test func aMaskThatIsAskedForAgainCanBeForgotten() {
        let cache = MaskRasterCache(folder: folder())
        let id = UUID()
        cache.store(grey, for: id)
        cache.forget(id)
        #expect(cache.raster(for: id) == nil)
    }

    /// A folder that does not exist yet, and one that cannot be written to: neither may take
    /// the app down. A mask that is not cached is simply found again.
    @Test func aCacheThatCannotBeWrittenIsNotAFailure() {
        let cache = MaskRasterCache(folder: URL(fileURLWithPath: "/dev/null/nowhere"))
        cache.store(grey, for: UUID())
        #expect(cache.raster(for: UUID()) == nil)
    }
}
