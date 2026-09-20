import Foundation

/// Which mood a photo wears, and how much of it. The document names the LUT; it never
/// carries it, so that the settings of a photo stay a few lines of readable JSON whatever
/// the size of the table behind them.
public struct LUTSetting: Codable, Equatable, Sendable {
    /// The name of the `.cube` file, without its extension.
    public var name: String
    /// From 0 to 100.
    public var amount: Double

    public init(name: String, amount: Double = 100) {
        self.name = name
        self.amount = amount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 100
    }

    func sanitized() -> LUTSetting {
        LUTSetting(name: name, amount: amount.bounded(to: AdjustmentLimits.unipolar, else: 100))
    }
}

/// A folder of `.cube` files: the moods someone made elsewhere or bought as a pack. The
/// folder is the source of truth, as it is for looks and export presets; nothing is cached
/// between calls, so a file dropped in shows up at once.
///
/// A name comes from a settings document, which may have been written by anyone: it is made
/// a plain file name, and the file it leads to is checked to sit right in the folder.
public struct LUTLibrary: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The name of every `.cube` of the folder, sorted, whether or not it can be read: a file
    /// that is there and broken must be shown and say so, not quietly vanish.
    public func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == Self.fileExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Where the LUT called `name` lives. Always inside the folder, whatever `name` holds.
    public func url(for name: String) -> URL {
        let safe = FileName.sanitized(name, fallback: FileName.lastResort, reserving: Self.fileExtension.utf8.count + 1)
        return directory.appendingPathComponent(safe).appendingPathExtension(Self.fileExtension)
    }

    public func lut(named name: String) throws -> CubeLUT {
        let file = url(for: name)
        guard FileName.isContained(file, in: directory), FileManager.default.fileExists(atPath: file.path) else {
            throw RawEngineError.unknownLUT(name)
        }
        return try CubeLUT(contentsOf: file)
    }

    static let fileExtension = "cube"

    /// `~/Library/Application Support/SimpleRAW/LUTs`.
    public static let applicationSupport: LUTLibrary = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LUTLibrary(directory: base.appendingPathComponent("SimpleRAW").appendingPathComponent("LUTs"))
    }()
}
