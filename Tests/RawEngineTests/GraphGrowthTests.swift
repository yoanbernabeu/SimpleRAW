import CoreImage
import Foundation
import TestSupport
import Testing
@testable import RawEngine

/// Spots and layers are chains: each one works on the result of the one before, and reads it
/// twice (once as the background, once shifted or adjusted). Were Core Image to fold such a
/// chain into one program, its size would double with every link.
///
/// So the cost of a chain must grow in line with its length. Measured on short chains, where
/// doubling would be slow but harmless.
@Suite(.serialized) struct GraphGrowthTests {
    let probe = PixelProbe()
    let picture = PixelProbe.swatch(r: 0.4, g: 0.5, b: 0.6, size: CGSize(width: 256, height: 256))

    private func milliseconds(_ render: () throws -> Void) rethrows -> Double {
        try render()  // Shaders compile the first time.
        let start = Date()
        try render()
        return Date().timeIntervalSince(start) * 1000
    }

    private func spots(_ count: Int) -> Adjustments {
        var adjustments = Adjustments()
        adjustments.spots = (0..<count).map { index in
            let x = 0.1 + 0.8 * Double(index) / Double(max(count - 1, 1))
            return Spot(target: .init(x: x, y: 0.5), source: .init(x: x, y: 0.2), radius: 0.03)
        }
        return adjustments
    }

    private func layers(_ count: Int) -> Adjustments {
        var adjustments = Adjustments()
        var settings = LocalSettings()
        settings.exposure = 0.1
        adjustments.locals = (0..<count).map { index in
            let x = 0.1 + 0.8 * Double(index) / Double(max(count - 1, 1))
            return LocalAdjustment(mask: .radial(RadialMask(center: .init(x: x, y: 0.5), radiusX: 0.2, radiusY: 0.2)), settings: settings)
        }
        return adjustments
    }

    /// One small spot on a screen-sized picture asked for ten gigabytes a second, and rebooted
    /// the computer: its mask was an infinite gradient drawn a thousand pixels wide, then
    /// scaled down thirty-fold, which Core Image does by rendering the large one first.
    @Test(arguments: [0.003, 0.012, 0.05])
    func aSmallDiscIsACheapMask(radius: Double) throws {
        MemoryFuse.arm()
        let screen = PixelProbe.swatch(r: 0.4, g: 0.5, b: 0.6, size: CGSize(width: 2300, height: 1533))
        var adjustments = Adjustments()
        adjustments.spots = [Spot(target: .init(x: 0.06, y: 0.1), source: .init(x: 0.09, y: 0.12), radius: radius)]
        // A pool around the render, and the measurement taken after it has drained. Core Image
        // hands its buffers back through autorelease: without this the number is whatever the
        // rest of the suite happened to be holding at the time, and this test goes off on its
        // own every so often for a reason that has nothing to do with the spot.
        let before = MemoryFuse.footprint
        try autoreleasepool {
            _ = try probe.average(of: SpotRemovalStage().apply(adjustments, to: screen))
        }
        let grown = Double(MemoryFuse.footprint) - Double(before)
        #expect(grown < 500_000_000, "a spot of radius \(radius) took \(grown / 1e9) GB")
    }

    @Test func twelveSpotsDoNotCostAThousandTimesThree() throws {
        let few = try milliseconds { _ = try probe.average(of: SpotRemovalStage().apply(spots(3), to: picture)) }
        let many = try milliseconds { _ = try probe.average(of: SpotRemovalStage().apply(spots(12), to: picture)) }
        print(String(format: "GRAPH spots: 3 → %.1f ms, 12 → %.1f ms", few, many))
        #expect(many < few * 12 + 20, "3 spots: \(few) ms, 12 spots: \(many) ms")
    }

    @Test func twelveLayersDoNotCostAThousandTimesThree() throws {
        let few = try milliseconds { _ = try probe.average(of: LocalAdjustmentsStage().apply(layers(3), to: picture)) }
        let many = try milliseconds { _ = try probe.average(of: LocalAdjustmentsStage().apply(layers(12), to: picture)) }
        print(String(format: "GRAPH layers: 3 → %.1f ms, 12 → %.1f ms", few, many))
        #expect(many < few * 12 + 20, "3 layers: \(few) ms, 12 layers: \(many) ms")
    }
}
