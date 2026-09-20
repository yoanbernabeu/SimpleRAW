import Foundation

public enum RawEngineError: Error, LocalizedError, Equatable {
    case unsupportedFile(URL)
    /// A folder, a broken link, a device: nothing a decoder should be handed.
    case notARegularFile(URL)
    case unsupportedAdjustmentsVersion(Int)
    case noEmbeddedPreview(URL)
    /// - Parameter underlying: what the system said went wrong: no such folder, disk full…
    case exportFailed(URL, underlying: String)
    case analysisFailed
    case unknownPreset(String, available: [String])
    /// No `.cube` of that name in the LUT folder.
    case unknownLUT(String)
    case tooManyItems(String, count: Int, limit: Int)
    /// A `name=value` that cannot be applied, and why.
    case invalidSetting(String, reason: String)
    case fileTooLarge(URL, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            "Unreadable RAW file or unsupported camera: \(url.lastPathComponent)"
        case .unsupportedAdjustmentsVersion(let version):
            "Adjustments are version \(version), newer than the supported one (\(Adjustments.currentVersion))"
        case .noEmbeddedPreview(let url):
            "No embedded preview in \(url.lastPathComponent)"
        case .notARegularFile(let url):
            "\(url.lastPathComponent) is not a file"
        case .exportFailed(let url, let underlying):
            "Export failed: \(url.path) (\(underlying))"
        case .analysisFailed:
            "The image could not be analyzed"
        case .invalidSetting(let text, let reason):
            "Cannot set \"\(text)\": \(reason)"
        case .tooManyItems(let what, let count, let limit):
            "Too many \(what): \(count), the limit is \(limit)"
        case .fileTooLarge(let url, let limit):
            "\(url.lastPathComponent) is too large (the limit is \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))"
        case .unknownLUT(let name):
            "No LUT named \"\(name)\" in your LUTs folder"
        case .unknownPreset(let name, let available):
            "No preset named \"\(name)\". Available: \(available.isEmpty ? "none" : available.joined(separator: ", "))"
        }
    }
}
