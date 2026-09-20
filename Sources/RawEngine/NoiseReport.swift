import CoreImage
import Foundation

/// What can be done about the noise in one photograph, measured rather than guessed.
///
/// Denoising is the one part of this engine nobody can judge by reading code: it depends on
/// the camera, on the ISO, and on what the decoder decided for that pair. So it is measured —
/// the same file rendered twice, once neutral and once with a setting pushed to its end, and
/// the average distance between the two. The scene cancels out; what is left is what the
/// setting did.
///
/// Measured on 20/09/2026, on a Ricoh GR III at ISO 100 and ISO 400: every noise setting
/// changes the picture by about 0.0004 — a tenth of a level out of 255, which nobody can see.
/// Sharpening, in the same measurement, changes it by 0.022. That is the whole reason this
/// type exists: the question of whether a photograph needs more than the decoder gives cannot
/// be answered on files that hold no noise, and saying so costs one command.
public struct NoiseReport: Sendable {
    /// One setting, pushed from neutral to its end.
    public struct Change: Sendable {
        public let name: String
        /// Mean absolute difference in luminance, from 0 to 1.
        public let amount: Double

        /// A level out of 255 is 0.0039. Half of one is the point below which a difference is
        /// not a difference — no screen shows it and no print carries it.
        public var isVisible: Bool { amount >= NoiseReport.visibleDifference }
    }

    public static let visibleDifference = 0.002

    public let iso: Int?
    public let isRaw: Bool
    /// The push the measurement was made at, in EV.
    public var exposure: Double = 0
    /// What the decoder chose for this camera and this ISO, which is where every slider of
    /// the app sits until it is moved.
    public let defaults: RawInfo.DecoderDefaults
    public let changes: [Change]

    /// Whether anything the app can do about noise on this file is worth doing.
    public var holdsVisibleNoiseControl: Bool {
        changes.contains { $0.isVisible && !$0.name.contains("comparison") }
    }

    /// The side of the square taken out of the middle of the picture, at full resolution:
    /// noise lives in the pixels, so it is measured there and not in a preview.
    public static let side = 512

    /// - Parameters:
    ///   - url: the photograph to measure.
    ///   - exposure: the photograph as it will be developed, in EV. Noise bites when a dark
    ///     frame is pushed back up, so measuring a recovered shot says more about what a
    ///     photographer will meet than measuring it as it came off the card.
    public static func measure(_ url: URL, exposure: Double = 0) throws -> NoiseReport {
        let source = try RawSource(url: url)
        let info = source.info
        let probe = PixelDistance(side: side)

        /// Across the whole travel of the slider, from one end to the other: what the
        /// photographer can do about it, not what the decoder happened to choose.
        func change(_ name: String, _ edit: @escaping (inout Adjustments, Double) -> Void) -> Change? {
            func rendered(_ value: Double) -> [Float]? {
                var adjustments = Adjustments()
                adjustments.exposure = exposure
                edit(&adjustments, value)
                return try? probe.pixels(of: source.image(adjustments: adjustments))
            }
            guard let lowest = rendered(0), let highest = rendered(100) else { return nil }
            return Change(name: name, amount: probe.distance(lowest, highest))
        }

        var changes: [Change] = []
        if info.capabilities.luminanceNoiseReduction {
            changes += [change("Luminance noise, 0 to 100", { $0.luminanceNoiseReduction = $1 })].compactMap { $0 }
        }
        if info.capabilities.colorNoiseReduction {
            changes += [change("Colour noise, 0 to 100", { $0.colorNoiseReduction = $1 })].compactMap { $0 }
        }
        // Not about noise, and that is the point: it is the yardstick. A setting everyone can
        // see moves this number by tens of thousandths, so one that moves it far less does not.
        if info.capabilities.sharpness {
            changes += [change("Sharpening, 0 to 100 (for comparison)", { $0.sharpness = $1 })].compactMap { $0 }
        }
        return NoiseReport(iso: info.iso, isRaw: info.isRaw, exposure: exposure, defaults: info.decoderDefaults, changes: changes)
    }
}

/// Renders a square out of the middle of a picture and compares two of them.
struct PixelDistance {
    let side: Int
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    struct CannotRender: Error {}

    func pixels(of image: CIImage) throws -> [Float] {
        let rect = CGRect(
            x: image.extent.midX - CGFloat(side) / 2, y: image.extent.midY - CGFloat(side) / 2,
            width: CGFloat(side), height: CGFloat(side)
        )
        guard !image.extent.isInfinite, image.extent.width >= 1, image.extent.height >= 1 else { throw CannotRender() }
        var pixels = [Float](repeating: 0, count: side * side * 4)
        context.render(
            image, toBitmap: &pixels, rowBytes: side * 16, bounds: rect,
            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return pixels
    }

    /// Mean absolute difference in luminance, so that one number says how far apart two
    /// renderings of the same photograph are.
    func distance(_ first: [Float], _ second: [Float]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var sum = 0.0
        for index in stride(from: 0, to: first.count, by: 4) {
            sum += abs(Double(luminance(first, index)) - Double(luminance(second, index)))
        }
        return sum / Double(first.count / 4)
    }

    private func luminance(_ pixels: [Float], _ index: Int) -> Float {
        0.2126 * pixels[index] + 0.7152 * pixels[index + 1] + 0.0722 * pixels[index + 2]
    }
}
