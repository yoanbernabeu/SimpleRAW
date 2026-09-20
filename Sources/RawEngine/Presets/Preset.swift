import Foundation

/// A reusable look: some groups of settings, and their values.
public struct Preset: Equatable, Sendable, Identifiable {
    public var name: String
    public var groups: Set<AdjustmentGroup>
    /// Neutral outside of `groups`.
    public private(set) var adjustments: Adjustments

    public var id: String { name }

    /// Keeps the chosen groups of `adjustments` only, so that a preset file never carries
    /// settings it does not mean to apply.
    public init(name: String, capturing adjustments: Adjustments, groups: Set<AdjustmentGroup>) {
        self.name = name
        self.groups = groups
        self.adjustments = Adjustments().applying(adjustments, groups: groups)
    }

    public func apply(to target: inout Adjustments) {
        target.apply(adjustments, groups: groups)
    }
}

/// Accepts the full form (`name`, `groups`, `adjustments`), the same without `groups`, and a
/// bare adjustments document such as `{"contrast": 20}`. Missing groups are read off the
/// fields that are present. Codable, so that a look can sit inside another document (an
/// import preset) and report what is wrong in it like any other value.
extension Preset: Codable {
    /// The name of a look that carries none: the name of its file, passed through `userInfo`.
    public static let fallbackNameKey = CodingUserInfoKey(rawValue: "simpleraw.preset.fallbackName")!

    private enum CodingKeys: String, CodingKey {
        case name, groups, adjustments
    }

    /// Whatever keys a document has.
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let fallbackName = decoder.userInfo[Self.fallbackNameKey] as? String ?? "Look"
        let document = try decoder.container(keyedBy: CodingKeys.self)
        guard document.contains(.adjustments) else {
            let fields = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
            // A bare document may still say what it is called; else it is called after its file.
            self.init(
                name: try document.decodeIfPresent(String.self, forKey: .name) ?? fallbackName,
                capturing: try Adjustments(from: decoder),
                groups: AdjustmentGroup.groups(presentIn: Set(fields))
            )
            return
        }
        let adjustments = try document.decode(Adjustments.self, forKey: .adjustments)
        let fields = try document.nestedContainer(keyedBy: AnyKey.self, forKey: .adjustments).allKeys.map(\.stringValue)
        let groups = try document.decodeIfPresent([AdjustmentGroup].self, forKey: .groups).map(Set.init)
        self.init(
            name: try document.decodeIfPresent(String.self, forKey: .name) ?? fallbackName,
            capturing: adjustments, groups: groups ?? AdjustmentGroup.groups(presentIn: Set(fields))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var document = encoder.container(keyedBy: CodingKeys.self)
        try document.encode(name, forKey: .name)
        try document.encode(AdjustmentGroup.allCases.filter(groups.contains), forKey: .groups)
        try document.encode(adjustments, forKey: .adjustments)
    }
}

extension Preset: StoredItem {
    /// A missing name is the name of the file.
    public static func decode(from data: Data, fallbackName: String) throws -> Preset {
        let decoder = JSONDecoder()
        decoder.userInfo[fallbackNameKey] = fallbackName
        return try decoder.decode(Preset.self, from: data)
    }
}
