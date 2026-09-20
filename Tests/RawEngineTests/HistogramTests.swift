import CoreImage
import Testing
import TestSupport
@testable import RawEngine

@Suite struct HistogramTests {
    let analyzer = HistogramAnalyzer()

    @Test func hasOneBinPerLevel() throws {
        let histogram = try analyzer.histogram(of: PixelProbe.swatch(r: 0.2, g: 0.2, b: 0.2))
        #expect(histogram.red.count == Histogram.binCount)
        #expect(histogram.green.count == Histogram.binCount)
        #expect(histogram.blue.count == Histogram.binCount)
    }

    /// Bins are display-referred: linear 0.214 is sRGB 0.5, so a mid-gray lands mid-scale.
    @Test func midGrayPeaksInTheMiddle() throws {
        let histogram = try analyzer.histogram(of: PixelProbe.swatch(r: 0.214, g: 0.214, b: 0.214))
        for channel in [histogram.red, histogram.green, histogram.blue] {
            let peak = try #require(channel.indices.max { channel[$0] < channel[$1] })
            #expect(abs(peak - Histogram.binCount / 2) <= 2)
        }
    }

    @Test func channelsAreIndependent() throws {
        let histogram = try analyzer.histogram(of: PixelProbe.swatch(r: 1, g: 0, b: 0))
        #expect(histogram.red.last! > 0.9)
        #expect(histogram.green.first! > 0.9)
        #expect(histogram.blue.first! > 0.9)
    }

    @Test func isNormalizedToItsTallestBin() throws {
        let histogram = try analyzer.histogram(of: PixelProbe.swatch(r: 0.5, g: 0.3, b: 0.1))
        let tallest = (histogram.red + histogram.green + histogram.blue).max()
        #expect(tallest == 1)
    }

    @Test func clippingIsReported() throws {
        let blown = try analyzer.histogram(of: PixelProbe.swatch(r: 1, g: 1, b: 1))
        let crushed = try analyzer.histogram(of: PixelProbe.swatch(r: 0, g: 0, b: 0))
        let safe = try analyzer.histogram(of: PixelProbe.swatch(r: 0.2, g: 0.2, b: 0.2))
        #expect(blown.clipsHighlights && !blown.clipsShadows)
        #expect(crushed.clipsShadows && !crushed.clipsHighlights)
        #expect(!safe.clipsHighlights && !safe.clipsShadows)
    }
}

@Suite struct PreviewScaleTests {
    let sensor = CGSize(width: 6000, height: 4000)

    @Test func decodesNoMorePixelsThanTheViewShows() {
        let scale = PreviewScale.factor(for: sensor, fitting: CGSize(width: 1500, height: 1000))
        #expect(scale == 0.25)
    }

    @Test func fitsTheConstrainingDimension() {
        // A tall, narrow view: width is what limits the image.
        let scale = PreviewScale.factor(for: sensor, fitting: CGSize(width: 600, height: 4000))
        #expect(scale == 0.1)
    }

    @Test func neverUpscales() {
        let scale = PreviewScale.factor(for: sensor, fitting: CGSize(width: 12000, height: 8000))
        #expect(scale == 1)
    }

    @Test func survivesAnEmptyView() {
        let scale = PreviewScale.factor(for: sensor, fitting: CGSize.zero)
        #expect(scale > 0 && scale <= 1)
    }
}
