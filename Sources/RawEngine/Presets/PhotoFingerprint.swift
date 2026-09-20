import CryptoKit
import Foundation

/// A short, stable name for a photograph that is not in the library.
///
/// It exists because a sandboxed app cannot keep a photograph's edits beside the photograph,
/// and has to keep them in a folder of its own where two files called `R0001.DNG` would
/// otherwise be one. The name of the folder it came from goes into it, so the same file opened
/// from the same place is always the same photograph.
///
/// Its size and the moment it was last written go in too, and its contents do not: reading
/// twenty-five megabytes to decide where to look for a settings file would be felt at every
/// open, for a photograph that is about to be read anyway. The trade is that a file edited by
/// something else looks like another photograph — which is the honest answer, since its
/// pixels are no longer the ones those settings were made for.
public enum PhotoFingerprint {
    public static func of(_ url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let written = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let standardized = url.standardizedFileURL
        let text = "\(standardized.path)|\(size)|\(Int(written))"
        return String(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}
