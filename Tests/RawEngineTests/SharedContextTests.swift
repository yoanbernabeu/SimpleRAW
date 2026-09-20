import CoreImage
import Foundation
import ImageIO
import Testing
import TestSupport
@testable import RawEngine

/// GPU contexts are expensive and safe to share between threads: there is one for background
/// rendering (exports, batches, thumbnails) and one for analysis (histogram, Auto).
@Suite struct SharedContextTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("simpleraw-shared-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func width(of url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return properties[kCGImagePropertyPixelWidth as String] as? Int
    }

    /// Thumbnails, a batch and an export may all be writing at once.
    @Test func theSharedRendererServesSeveralThreadsAtOnce() {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let renderer: any Sendable = Renderer.shared
        #expect(renderer is Renderer)
        let folder = folder
        DispatchQueue.concurrentPerform(iterations: 6) { index in
            let picture = PixelProbe.swatch(r: 0.1 * CGFloat(index), g: 0.3, b: 0.5, size: CGSize(width: 200 + index, height: 100))
            try? Renderer.shared.writeJPEG(picture, to: folder.appendingPathComponent("\(index).jpg"))
        }
        for index in 0..<6 {
            #expect(width(of: folder.appendingPathComponent("\(index).jpg")) == 200 + index)
        }
    }

    /// A full-size export gives its memory back; the renderer must still work afterwards.
    @Test func exportsFollowOneAnotherOnTheSameRenderer() throws {
        MemoryFuse.arm()
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = PixelProbe.swatch(r: 0.5, g: 0.3, b: 0.1, size: CGSize(width: 300, height: 200))
        var small = ExportOptions()
        small.longEdge = 150
        for (name, options) in [("full-1", ExportOptions()), ("small", small), ("full-2", ExportOptions())] {
            let destination = folder.appendingPathComponent("\(name).jpg")
            try Renderer.shared.write(picture, to: destination, options: options)
            #expect(width(of: destination) == (options.longEdge ?? 300))
        }
    }

    /// The histogram and Auto read levels the same way, because they read them through the
    /// same code: where the histogram peaks is where Auto finds the median.
    @Test(arguments: [0.05, 0.214, 0.6])
    func theHistogramAndAutoAgreeOnWhereTonesSit(linear: Double) throws {
        MemoryFuse.arm()
        let gray = PixelProbe.swatch(r: linear, g: linear, b: linear)
        let histogram = try HistogramAnalyzer().histogram(of: gray)
        let statistics = try ToneAnalyzer().statistics(of: gray)
        let peak = try #require(histogram.green.firstIndex(of: 1))
        #expect(statistics.p50 == Double(peak) / Double(Histogram.binCount - 1))
        #expect(statistics.p1 == statistics.p99)
    }

    @Test func levelsAreSharesOfThePictureThatAddUpToOne() throws {
        MemoryFuse.arm()
        let half = PixelProbe.swatch(r: 1, g: 0, b: 0.214, size: CGSize(width: 32, height: 64))
            .composited(over: PixelProbe.swatch(r: 0, g: 0, b: 0.214, size: CGSize(width: 64, height: 64)))
        let levels = try LevelsReader.shared.levels(of: half)
        #expect(levels.count == 3 && levels.allSatisfy { $0.count == LevelsReader.binCount })
        for channel in levels { #expect(abs(channel.reduce(0, +) - 1) < 0.001) }
        // Red: half black, half white. Blue: all at sRGB 0.5.
        #expect(abs(levels[0][0] - 0.5) < 0.01 && abs(levels[0][255] - 0.5) < 0.01)
        #expect(levels[2][127] + levels[2][128] > 0.99)
    }

    @Test func aPictureWithoutBoundsCannotBeAnalyzed() {
        #expect(throws: RawEngineError.analysisFailed) { try LevelsReader.shared.levels(of: CIImage(color: .gray)) }
    }
}
