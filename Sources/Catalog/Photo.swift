import CryptoKit
import Foundation
import RawEngine

public enum Flag: Int, Sendable, CaseIterable {
    case rejected = -1
    case none = 0
    case picked = 1
}

public enum ColorLabel: String, Sendable, CaseIterable {
    case red, yellow, green, blue, purple
}

/// What is known about a file when it enters the catalog: where it is, what it holds, and
/// its metadata, read as `photo.camera` or `photo.metadata.camera` alike.
@dynamicMemberLookup
public struct NewPhoto: Equatable, Sendable {
    /// Relative to the library folder, so that the library can be moved.
    public var relativePath: String
    public var fileName: String
    /// SHA-256 of the file: how an import recognizes a file it already has.
    public var contentHash: String
    public var metadata: FileMetadata

    public init(relativePath: String, fileName: String, contentHash: String, metadata: FileMetadata) {
        self.relativePath = relativePath
        self.fileName = fileName
        self.contentHash = contentHash
        self.metadata = metadata
    }

    public init(
        relativePath: String, fileName: String, contentHash: String, captureDate: Date?, camera: String?, lens: String?,
        iso: Int?, exposureTime: Double?, aperture: Double?, focalLength: Double?, width: Int, height: Int
    ) {
        self.init(relativePath: relativePath, fileName: fileName, contentHash: contentHash, metadata: FileMetadata(
            captureDate: captureDate, camera: camera, lens: lens, iso: iso, exposureTime: exposureTime, aperture: aperture,
            focalLength: focalLength, width: width, height: height
        ))
    }

    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<FileMetadata, Value>) -> Value {
        get { metadata[keyPath: keyPath] }
        set { metadata[keyPath: keyPath] = newValue }
    }
}

/// A photo of the catalog.
///
/// Reading a library must not cost one JSON document per photo: the edits of a row stay as
/// the catalog stores them and are decoded when first asked for, once for every copy of the
/// value. The grid shows thousands of photos and opens a few.
@dynamicMemberLookup
public struct Photo: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var file: NewPhoto
    public var importDate: Date
    public var rating: Int
    public var flag: Flag
    public var colorLabel: ColorLabel?
    /// What is said about the picture: title, caption, author, copyright. Read off the row,
    /// so that showing a title costs no query. Its `keywords` are always empty here — they
    /// live in their own tables; `PhotoCatalog.credits(for:)` is the value with them.
    public var credits: PhotoCredits

    private var edits: Edits
    /// The `is_edited` column: stored, so that it can be filtered on.
    private var flaggedAsEdited: Bool
    /// Only for a photo built in memory: a stored one finds out by decoding.
    private var flaggedAsUnreadable: Bool
    /// As saved next to the edits; `nil` once they have changed in memory.
    private var savedFingerprint: String?

    public init(
        id: Int64, file: NewPhoto, importDate: Date, rating: Int, flag: Flag, colorLabel: ColorLabel?,
        credits: PhotoCredits = PhotoCredits(), adjustments: Adjustments, isEdited: Bool, hasUnreadableAdjustments: Bool = false
    ) {
        self.init(id: id, file: file, importDate: importDate, rating: rating, flag: flag, colorLabel: colorLabel,
                  credits: credits, edits: Edits(adjustments), isEdited: isEdited,
                  hasUnreadableAdjustments: hasUnreadableAdjustments, fingerprint: nil)
    }

    /// A row of the catalog, its edits still as JSON.
    init(
        id: Int64, file: NewPhoto, importDate: Date, rating: Int, flag: Flag, colorLabel: ColorLabel?,
        credits: PhotoCredits, storedAdjustments: String?, isEdited: Bool, fingerprint: String?
    ) {
        self.init(id: id, file: file, importDate: importDate, rating: rating, flag: flag, colorLabel: colorLabel,
                  credits: credits, edits: storedAdjustments.map { .stored(StoredAdjustments(json: $0)) } ?? .neutral,
                  isEdited: isEdited, hasUnreadableAdjustments: false, fingerprint: storedAdjustments == nil ? nil : fingerprint)
    }

    private init(
        id: Int64, file: NewPhoto, importDate: Date, rating: Int, flag: Flag, colorLabel: ColorLabel?,
        credits: PhotoCredits, edits: Edits, isEdited: Bool, hasUnreadableAdjustments: Bool, fingerprint: String?
    ) {
        self.id = id
        self.file = file
        self.importDate = importDate
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
        self.credits = credits
        self.edits = edits
        flaggedAsEdited = isEdited
        flaggedAsUnreadable = hasUnreadableAdjustments
        savedFingerprint = fingerprint
    }

    /// Neutral when the photo has no edits, or none that this version can read.
    public var adjustments: Adjustments {
        get { edits.value ?? Adjustments() }
        set {
            edits = Edits(newValue)
            flaggedAsUnreadable = false
            savedFingerprint = nil
        }
    }

    /// Whether the adjustments differ from neutral.
    public var isEdited: Bool {
        get { flaggedAsEdited && !hasUnreadableAdjustments }
        set { flaggedAsEdited = newValue }
    }

    /// The catalog holds edits for this photo that this version cannot read: damaged, or
    /// written by a newer one. It shows as unedited, and its edits are kept, not overwritten.
    public var hasUnreadableAdjustments: Bool {
        get {
            if case .stored(let stored) = edits { return stored.value == nil }
            return flaggedAsUnreadable
        }
        set { flaggedAsUnreadable = newValue }
    }

    /// What names the thumbnail of the photo as it is now. Read from the row, so that drawing
    /// a cell of the grid encodes and hashes nothing; computed only for edits made in memory.
    /// - Throws: if those cannot be encoded. They never borrow the fingerprint of neutral ones.
    public var adjustmentsFingerprint: String {
        get throws {
            if let savedFingerprint { return savedFingerprint }
            switch edits {
            case .neutral: return AdjustmentsFingerprint.neutral
            case .value(let adjustments): return try AdjustmentsFingerprint.of(adjustments)
            case .stored(let stored): return AdjustmentsFingerprint.of(json: Data(stored.json.utf8))
            }
        }
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<NewPhoto, Value>) -> Value {
        file[keyPath: keyPath]
    }

    public static func == (a: Photo, b: Photo) -> Bool {
        a.id == b.id && a.rating == b.rating && a.flag == b.flag && a.colorLabel == b.colorLabel
            && a.credits == b.credits && a.flaggedAsEdited == b.flaggedAsEdited && a.importDate == b.importDate
            && a.file == b.file && a.edits == b.edits && a.hasUnreadableAdjustments == b.hasUnreadableAdjustments
    }
}

/// The edits of a photo, in whichever form they are at hand.
private enum Edits: Equatable, Sendable {
    case neutral
    /// Boxed: a photo is copied around by the thousand, and most have no edits.
    indirect case value(Adjustments)
    case stored(StoredAdjustments)

    init(_ adjustments: Adjustments) {
        self = adjustments == Adjustments() ? .neutral : .value(adjustments)
    }

    var value: Adjustments? {
        switch self {
        case .neutral: nil
        case .value(let adjustments): adjustments
        case .stored(let stored): stored.value
        }
    }

    static func == (a: Edits, b: Edits) -> Bool {
        // Two readings of the same row: nothing to decode to tell that they are equal.
        if case .stored(let a) = a, case .stored(let b) = b, a === b || a.json == b.json { return true }
        return (a.value ?? Adjustments()) == (b.value ?? Adjustments())
    }
}

/// Edits as the catalog stores them, decoded on first use. A class, so that every copy of a
/// `Photo` shares the one decoding.
final class StoredAdjustments: @unchecked Sendable {
    let json: String
    private let lock = NSLock()
    /// Guarded by `lock`. `.some(nil)`: tried, and unreadable.
    private var decoded: Adjustments??

    init(json: String) {
        self.json = json
    }

    var value: Adjustments? {
        lock.withLock {
            if let decoded { return decoded }
            let value = Self.decode(json)
            decoded = .some(value)
            return value
        }
    }

    /// One decoder for every row: making one costs more than decoding small edits.
    private static let decoder = JSONDecoder()

    static func decode(_ json: String) -> Adjustments? {
        try? decoder.decode(Adjustments.self, from: Data(json.utf8))
    }
}

/// A short name for a set of edits. The JSON form is deterministic (sorted keys), so equal
/// adjustments share a fingerprint.
enum AdjustmentsFingerprint {
    static let neutral = "neutral"

    static func of(_ adjustments: Adjustments) throws -> String {
        adjustments == Adjustments() ? neutral : of(json: try adjustments.jsonData())
    }

    static func of(json: Data) -> String {
        ContentHash.hex(SHA256.hash(data: json).prefix(8))
    }
}

public struct Album: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var name: String
}

public struct KeywordCount: Equatable, Sendable {
    public let name: String
    public let count: Int
}
