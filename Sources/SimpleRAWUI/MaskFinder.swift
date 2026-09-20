import CoreImage
import Foundation
import RawEngine
import Vision

/// Asks Vision what is in a picture, off the main actor. It owns a decoder of its own,
/// because the on-screen one is not thread-safe — the same arrangement as `ZoomCacheWorker`.
///
/// What is found is a grey picture: white over what was found, black elsewhere. It is kept at
/// the size it was computed at, which is a fraction of the photograph: a mask is a soft thing
/// and nobody can see the difference, while a full-size one would cost a hundred megabytes.
///
/// Measured on 20/09/2026, on four DNGs: a request costs 12–13 ms at 2048 px as at 1024 px,
/// on an already decoded picture. What is expensive is the **first** call of the process,
/// which loads the model — 153 ms for the subject, 2.3 s for people. That is what has to stay
/// off the main thread; the rest is nothing.
actor MaskFinder {
    /// The longest side the picture is handed to Vision at. Past this the answer does not get
    /// better, and the raster costs more to keep.
    static let workingSide: CGFloat = 1536

    private var source: RawSource?
    private var url: URL?
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// What was found for one photo, so that a second layer on the same subject asks Vision
    /// nothing: the instances of one request are all found together anyway.
    private var lastAnswer: (url: URL, subject: DetectedMask.Subject, masks: [CIImage])?

    /// The picture of one instance, or `nil` when there is nothing there to find — a landscape
    /// with no subject detached from its background, a photograph with nobody in it.
    ///
    /// Nothing about this throws: a mask that cannot be found is a mask that is not there, and
    /// the layer it belongs to simply changes nothing.
    func mask(of subject: DetectedMask.Subject, instance: Int, in url: URL) -> CIImage? {
        let masks = instances(of: subject, in: url)
        guard instance >= 0, instance < masks.count else { return nil }
        return masks[instance]
    }

    /// How many of that sort of thing are in the photograph: what the interface offers to
    /// choose between.
    func count(of subject: DetectedMask.Subject, in url: URL) -> Int {
        instances(of: subject, in: url).count
    }

    private func instances(of subject: DetectedMask.Subject, in url: URL) -> [CIImage] {
        if let lastAnswer, lastAnswer.url == url, lastAnswer.subject == subject { return lastAnswer.masks }
        let masks = find(subject, in: url)
        lastAnswer = (url, subject, masks)
        return masks
    }

    private func find(_ subject: DetectedMask.Subject, in url: URL) -> [CIImage] {
        guard let picture = decoded(url) else { return [] }
        let handler = VNImageRequestHandler(cgImage: picture, options: [:])
        let request: VNImageBasedRequest = switch subject {
        case .subject: VNGenerateForegroundInstanceMaskRequest()
        case .person: VNGeneratePersonInstanceMaskRequest()
        }
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNInstanceMaskObservation else { return [] }
        // Each instance on its own, in the order Vision found them, so that "the second
        // person" means the same thing from one opening of the photo to the next.
        return observation.allInstances.compactMap { instance in
            guard let buffer = try? observation.generateScaledMaskForImage(forInstances: [instance], from: handler) else { return nil }
            return CIImage(cvPixelBuffer: buffer)
        }
    }

    /// The photograph at a size Vision is happy with, decoded once per file.
    private func decoded(_ url: URL) -> CGImage? {
        if self.url != url {
            source = try? RawSource(url: url)
            self.url = url
            lastAnswer = nil
        }
        guard let source else { return nil }
        let size = source.info.imageSize
        let scale = Self.workingSide / max(size.width, size.height)
        // Vision reads the photograph, not the edit: what is a person is a person whatever
        // the exposure, and asking again after every slider would be absurd.
        guard let image = try? source.image(adjustments: Adjustments(), scaleFactor: Float(min(scale, 1))) else { return nil }
        return context.createCGImage(image, from: image.extent)
    }
}
