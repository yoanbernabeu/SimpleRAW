import CoreImage
import Foundation
import Testing
import TestSupport
@testable import RawEngine

/// Measuring what can be done about the noise in a photograph, rather than assuming it.
@Suite struct NoiseReportTests {
    /// Half a level out of 255: the point below which a difference is not one.
    @Test func whatCountsAsVisibleIsHalfALevel() {
        #expect(abs(NoiseReport.visibleDifference - 0.002) < 1e-9)
        #expect(!NoiseReport.Change(name: "x", amount: 0.0004).isVisible, "a tenth of a level is nothing")
        #expect(NoiseReport.Change(name: "x", amount: 0.02).isVisible)
    }

    /// The comparison line is a yardstick, not an answer: a file where only sharpening shows
    /// is a file with no noise to work on.
    @Test func theYardstickIsNotCountedAsNoiseControl() {
        let report = NoiseReport(
            iso: 100, isRaw: true, defaults: RawInfo.DecoderDefaults(sharpness: 85, luminanceNoiseReduction: 0, colorNoiseReduction: 50),
            changes: [
                .init(name: "Luminance noise, 0 to 100", amount: 0.0007),
                .init(name: "Sharpening, 0 to 100 (for comparison)", amount: 0.022),
            ]
        )
        #expect(!report.holdsVisibleNoiseControl, "sharpening is the yardstick, not the answer")

        let noisy = NoiseReport(
            iso: 6400, isRaw: true, defaults: report.defaults,
            changes: [.init(name: "Luminance noise, 0 to 100", amount: 0.03)]
        )
        #expect(noisy.holdsVisibleNoiseControl)
    }

    /// A rendered file has no RAW decoder behind it, so there is nothing of this kind to
    /// measure — and the report says so rather than printing zeros as if they meant something.
    @Test func aFileThatIsNotARawHasNoDecoderToAsk() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "simpleraw-noise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "flat.jpg")
        try Renderer.shared.writeJPEG(PixelProbe.swatch(r: 0.4, g: 0.4, b: 0.4, size: CGSize(width: 900, height: 700)), to: file)

        let report = try NoiseReport.measure(file)
        #expect(!report.isRaw)
        #expect(report.changes.isEmpty, "there is no decoder here to ask")
        #expect(!report.holdsVisibleNoiseControl)
    }

    /// The measurement itself: two renderings of the same square, and how far apart they are.
    @Test func theDistanceIsMeanAbsoluteLuminance() throws {
        let probe = PixelDistance(side: 64)
        let grey = try probe.pixels(of: PixelProbe.swatch(r: 0.5, g: 0.5, b: 0.5, size: CGSize(width: 200, height: 200)))
        let same = try probe.pixels(of: PixelProbe.swatch(r: 0.5, g: 0.5, b: 0.5, size: CGSize(width: 200, height: 200)))
        #expect(probe.distance(grey, same) < 1e-6, "the same picture is no distance from itself")

        // Further apart reads as further apart. The exact number depends on the transfer
        // function the square is rendered through, which is not what this measures.
        let lighter = try probe.pixels(of: PixelProbe.swatch(r: 0.6, g: 0.6, b: 0.6, size: CGSize(width: 200, height: 200)))
        let lightest = try probe.pixels(of: PixelProbe.swatch(r: 0.8, g: 0.8, b: 0.8, size: CGSize(width: 200, height: 200)))
        #expect(probe.distance(grey, lighter) > 0.01)
        #expect(probe.distance(grey, lightest) > probe.distance(grey, lighter))
    }

    /// A photograph is measured as it will be developed, not as it came off the card: a dark
    /// frame pushed back up is where noise bites. It is **not** a stand-in for a high ISO,
    /// though — pushing a well-exposed frame clips the highlights before it reveals the noise
    /// in the shadows, and the yardstick collapses with everything else. Measured, not assumed.
    @Test func aPhotographCanBeMeasuredAsItWillBeDeveloped() throws {
        try #require(Sample.url != nil, "needs a DNG in Samples/")
        MemoryFuse.arm()
        let url = try #require(Sample.url)
        let asShot = try NoiseReport.measure(url)
        let pushed = try NoiseReport.measure(url, exposure: 3)
        #expect(asShot.exposure == 0 && pushed.exposure == 3)
        #expect(pushed.changes.count == asShot.changes.count)
        #expect(pushed.changes.allSatisfy { $0.amount >= 0 })
    }

    /// On a real RAW: what this is for. The numbers depend on the camera and the ISO, so what
    /// is asserted is the shape of the answer — every setting the decoder supports is measured,
    /// and the yardstick is there to compare them against.
    @Test func aRealRawIsMeasuredSettingBySetting() throws {
        try #require(Sample.url != nil, "needs a DNG in Samples/")
        MemoryFuse.arm()
        let report = try NoiseReport.measure(try #require(Sample.url))
        #expect(report.isRaw)
        #expect(report.changes.count >= 2)
        #expect(report.changes.contains { $0.name.contains("comparison") })
        #expect(report.changes.allSatisfy { $0.amount >= 0 && $0.amount <= 1 })
    }
}
