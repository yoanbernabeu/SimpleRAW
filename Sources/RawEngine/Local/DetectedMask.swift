import CoreImage
import Foundation

/// A mask the machine found rather than one the photographer drew: the subject of the
/// picture, a person in it.
///
/// **What is stored is never the pixels.** The settings of a photo are a small JSON document
/// that has to stay readable and quick to decode by the thousand; a mask in pixels would be
/// neither. What is kept is what was asked for — the sort of mask and which of the instances
/// found — and the picture of it is computed again when the photo is opened, and cached like
/// a thumbnail.
///
/// The `id` is how the raster is found again: it is made once, stored with the mask, and is
/// the key into `MaskRasterStore`. It carries no identity of the photo, because it does not
/// need one — a mask belongs to one layer of one photo and nothing else.
public struct DetectedMask: Codable, Equatable, Sendable, Identifiable {
    /// What Vision is asked for.
    public enum Subject: String, Codable, CaseIterable, Sendable {
        /// What the picture is of: the thing that stands out from its background.
        case subject
        /// One person among those in the frame.
        case person
    }

    public let id: UUID
    public var subject: Subject
    /// Which of the instances found, counting from zero. More than one person, more than one
    /// subject: the photographer picks.
    public var instance: Int
    public var isInverted: Bool
    /// What the photographer added to or took away from what was found, by hand. Detection
    /// misses a strand of hair and takes in a shoulder that was not wanted: without this the
    /// tool is a party trick, with it it is a tool.
    public var corrections: BrushMask

    public init(
        id: UUID = UUID(), subject: Subject, instance: Int = 0, isInverted: Bool = false,
        corrections: BrushMask = BrushMask()
    ) {
        self.id = id
        self.subject = subject
        self.instance = instance
        self.isInverted = isInverted
        self.corrections = corrections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        subject = try container.decodeIfPresent(Subject.self, forKey: .subject) ?? .subject
        instance = try container.decodeIfPresent(Int.self, forKey: .instance) ?? 0
        isInverted = try container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
        corrections = try container.decodeIfPresent(BrushMask.self, forKey: .corrections) ?? BrushMask()
    }

    /// The strokes that add to what was found, and those that take away, each as a mask of
    /// its own: they are combined differently, one over the answer and one out of it.
    var addedAndRemoved: (added: BrushMask?, removed: BrushMask?) {
        func mask(erasing: Bool) -> BrushMask? {
            // Painted as plain strokes either way: what tells them apart is how they are
            // combined with what was found, not how they are drawn.
            let strokes = corrections.strokes
                .filter { $0.isErasing == erasing }
                .map { BrushMask.Stroke(points: $0.points, radius: $0.radius) }
            return strokes.isEmpty ? nil : BrushMask(strokes: strokes)
        }
        return (mask(erasing: false), mask(erasing: true))
    }
}

/// The pictures of the masks the machine found, by the id of the mask that asked for them.
///
/// `Mask.image(in:)` is pure and synchronous, and `DevelopPipeline.standard` is one shared
/// thing used by the canvas, the thumbnails and the exports at once. A mask that takes time
/// to find has nowhere to go in that arrangement — so it is put here, and the mask asks.
/// A raster that is not here yet answers **black**, which is a mask that changes nothing:
/// the picture shows as it was until the answer arrives, rather than flickering.
///
/// Rasters are kept at the size they were computed at and scaled to whatever they are asked
/// for, exactly as painted masks are: a mask is a soft thing, and nobody can see the
/// difference.
public final class MaskRasterStore: @unchecked Sendable {
    /// The one every pipeline reads. A mask found for one photo is wanted by the canvas, by
    /// the thumbnail of that photo and by its export, so there is no point in one store each.
    public static let shared = MaskRasterStore()

    /// How many rasters are kept. A photo rarely carries more than a handful of masks, and
    /// the filmstrip may be decoding a few photos around it.
    public static let capacity = 24

    private let lock = NSLock()
    /// Most recently used last.
    private var order: [UUID] = []
    private var rasters: [UUID: CIImage] = [:]

    public init() {}

    public func raster(for id: UUID) -> CIImage? {
        lock.withLock {
            guard let raster = rasters[id] else { return nil }
            order.removeAll { $0 == id }
            order.append(id)
            return raster
        }
    }

    public func store(_ raster: CIImage, for id: UUID) {
        lock.withLock {
            rasters[id] = raster
            order.removeAll { $0 == id }
            order.append(id)
            while order.count > Self.capacity, let oldest = order.first {
                order.removeFirst()
                rasters[oldest] = nil
            }
        }
    }

    public func forget(_ id: UUID) {
        lock.withLock {
            rasters[id] = nil
            order.removeAll { $0 == id }
        }
    }

    /// Whether a mask has its picture yet: what the interface says while one is being found.
    public func holdsRaster(for id: UUID) -> Bool {
        lock.withLock { rasters[id] != nil }
    }

    public func removeAll() {
        lock.withLock {
            rasters.removeAll()
            order.removeAll()
        }
    }
}
