import Foundation
import RawEngine

/// What to do to photos as they come in.
public struct ImportPreset: Codable, Equatable, Sendable, Identifiable, StoredItem {
    public var name: String
    /// Applied to every imported photo.
    public var look: Preset?
    public var keywords: [String] = []
    /// Who made the pictures and who owns them, written on every photo of the card. A title
    /// and a caption are not here: they name one picture, and an import has not seen any.
    public var author: String?
    public var copyright: String?
    /// `{name}` is the original file name, `{date}` the capture time as `20260911-111440`.
    public var fileNameTemplate = "{name}"

    /// Whether there is anything to sign the imported photos with.
    var signs: Bool { PhotoCredits.nonBlank(author) != nil || PhotoCredits.nonBlank(copyright) != nil }

    public var id: String { name }

    public init(name: String) {
        self.name = name
    }

    /// Partial documents are valid, as for every preset: what a hand-written file leaves out
    /// keeps its default.
    public init(from decoder: Decoder) throws {
        let document = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try document.decode(String.self, forKey: .name))
        look = try document.decodeIfPresent(Preset.self, forKey: .look)
        keywords = try document.decodeIfPresent([String].self, forKey: .keywords) ?? keywords
        author = try document.decodeIfPresent(String.self, forKey: .author)
        copyright = try document.decodeIfPresent(String.self, forKey: .copyright)
        fileNameTemplate = try document.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? fileNameTemplate
    }

    public static let builtIns = [ImportPreset(name: "As shot")]
}
