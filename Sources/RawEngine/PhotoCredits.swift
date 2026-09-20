import Foundation

/// What one picture says about itself: the photographer's own work, as opposed to what the
/// camera wrote. It travels with the file that leaves, whatever an export keeps of the rest.
///
/// An export preset carries an author and a copyright for a whole batch; these are the ones
/// of a single photo, and they win over the preset's. A title and a caption exist here only:
/// no preset can have them, because they name one picture.
public struct PhotoCredits: Equatable, Sendable {
    public var title: String?
    public var caption: String?
    public var author: String?
    public var copyright: String?
    public var keywords: [String]

    public init(title: String? = nil, caption: String? = nil, author: String? = nil, copyright: String? = nil, keywords: [String] = []) {
        self.title = Self.nonBlank(title)
        self.caption = Self.nonBlank(caption)
        self.author = Self.nonBlank(author)
        self.copyright = Self.nonBlank(copyright)
        self.keywords = keywords
    }

    /// Blank is nothing: an empty line is never written into a file, nor stored. The one rule,
    /// used by everything that takes one of these fields from a text field or a preset.
    public static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Nothing to say: the photo is signed by the export preset alone, as it was before the
    /// catalog held these fields.
    public var isEmpty: Bool {
        title == nil && caption == nil && author == nil && copyright == nil && keywords.isEmpty
    }

    /// The keywords as they go into the file: trimmed, blanks and repeats gone, in the order
    /// they were given.
    public var writtenKeywords: [String] {
        var written: [String] = []
        for keyword in keywords.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !keyword.isEmpty && !written.contains(keyword) {
            written.append(keyword)
        }
        return written
    }
}
