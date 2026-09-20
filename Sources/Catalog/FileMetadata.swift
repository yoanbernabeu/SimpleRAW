import Foundation
import RawEngine

/// What an import needs to know about a file, besides its bytes.
public struct FileMetadata: Equatable, Sendable {
    public var captureDate: Date?
    public var camera: String?
    public var lens: String?
    public var iso: Int?
    public var exposureTime: Double?
    public var aperture: Double?
    public var focalLength: Double?
    public var width: Int
    public var height: Int

    public init(captureDate: Date?, camera: String?, lens: String?, iso: Int?, exposureTime: Double?, aperture: Double?, focalLength: Double?, width: Int, height: Int) {
        self.captureDate = captureDate
        self.camera = camera
        self.lens = lens
        self.iso = iso
        self.exposureTime = exposureTime
        self.aperture = aperture
        self.focalLength = focalLength
        self.width = width
        self.height = height
    }

    /// Read from the RAW file itself, by the engine.
    public static func read(from url: URL) throws -> FileMetadata {
        let info = try RawSource(url: url).info
        return FileMetadata(
            captureDate: info.captureDate,
            camera: info.model ?? info.make, lens: info.lens, iso: info.iso, exposureTime: info.exposureTime,
            aperture: info.aperture, focalLength: info.focalLength,
            width: Int(info.imageSize.width), height: Int(info.imageSize.height)
        )
    }
}
