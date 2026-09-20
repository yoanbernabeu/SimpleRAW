import CoreImage
import Foundation
import RawEngine

/// Computes histograms off the main actor. It owns a decoder of its own, because the
/// on-screen one is not thread-safe, and it is asked for the finished picture at a small
/// size: plenty for 256 bins.
actor HistogramWorker {
    /// Long edge of the image the histogram is computed on.
    private static let size = CGSize(width: 512, height: 512)

    private var source: RawSource?
    private var url: URL?
    private let analyzer = HistogramAnalyzer()

    func histogram(of url: URL, adjustments: Adjustments) -> Histogram? {
        if self.url != url {
            source = try? RawSource(url: url)
            self.url = url
        }
        guard let source else { return nil }
        let shown = adjustments.geometry.outputSize(for: source.info.imageSize)
        let scale = PreviewScale.factor(for: shown, fitting: Self.size)
        guard let image = try? source.image(adjustments: adjustments, scaleFactor: scale) else { return nil }
        return try? analyzer.histogram(of: image)
    }
}
