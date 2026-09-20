import Foundation

/// Reads the small JSON documents of the app: settings, looks, export presets.
enum DocumentFile {
    /// Far more than any of them weighs (a heavily painted photo is a few hundred kilobytes).
    static let maximumSize = 8 * 1024 * 1024

    /// The contents of the file, its size checked before a single byte is read: a file of
    /// gigabytes dropped in the presets folder must not be loaded to find out it is not one.
    static func data(contentsOf url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumSize else { throw RawEngineError.fileTooLarge(url, limit: maximumSize) }
        return try Data(contentsOf: url)
    }
}
