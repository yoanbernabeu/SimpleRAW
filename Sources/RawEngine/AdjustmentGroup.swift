import Foundation

/// The families of settings that travel together: what a preset carries, what copy and paste
/// moves, what a batch applies. One mechanism, `Adjustments.apply(_:groups:)`, serves them all.
public enum AdjustmentGroup: String, CaseIterable, Codable, Sendable {
    case light, curve, whiteBalance, color, hsl, grading, effects, detail, optics, geometry, local, spots

    /// What copying settings offers by default: framing and masks belong to one picture.
    public static let defaultSelection = Set(allCases).subtracting([.geometry, .local, .spots])

    public var title: String {
        switch self {
        case .light: "Light"
        case .curve: "Curve"
        case .whiteBalance: "White balance"
        case .color: "Color"
        case .hsl: "HSL"
        case .grading: "Color grading"
        case .effects: "Effects"
        case .detail: "Detail"
        case .optics: "Optics"
        case .geometry: "Geometry"
        case .local: "Local adjustments"
        case .spots: "Spot removal"
        }
    }

    /// Each field of `Adjustments` belongs to exactly one group; a test enforces it, so that a
    /// new field cannot silently stay out of presets.
    private var members: [Member] {
        switch self {
        case .light: [
            Member("exposure", \.exposure), Member("contrast", \.contrast),
            Member("highlights", \.highlights), Member("shadows", \.shadows),
            Member("whites", \.whites), Member("blacks", \.blacks),
        ]
        case .curve: [Member("curves", \.curves)]
        case .whiteBalance: [Member("whiteBalance", \.whiteBalance)]
        case .color: [Member("vibrance", \.vibrance), Member("saturation", \.saturation), Member("blackAndWhite", \.blackAndWhite)]
        case .hsl: [Member("hsl", \.hsl)]
        case .grading: [Member("grading", \.grading), Member("lut", \.lut)]
        case .effects: [
            Member("enhance", \.enhance),
            Member("clarity", \.clarity), Member("structure", \.structure), Member("dehaze", \.dehaze),
            Member("glow", \.glow), Member("grain", \.grain),
        ]
        case .detail: [
            Member("sharpness", \.sharpness),
            Member("luminanceNoiseReduction", \.luminanceNoiseReduction),
            Member("colorNoiseReduction", \.colorNoiseReduction),
        ]
        case .optics: [
            Member("lensCorrection", \.lensCorrection), Member("aberration", \.aberration),
            Member("purpleFringe", \.purpleFringe),
            Member("distortion", \.distortion),
            Member("vignetting", \.vignetting),
        ]
        case .geometry: [Member("geometry", \.geometry)]
        case .local: [Member("locals", \.locals)]
        case .spots: [Member("spots", \.spots)]
        }
    }

    /// Names of the group's fields, as written in the JSON document.
    var fields: [String] { members.map(\.field) }

    fileprivate func copy(from source: Adjustments, to target: inout Adjustments) {
        for member in members { member.copy(source, &target) }
    }

    /// The groups a JSON document mentions: how a hand-written, partial document tells what it
    /// means to change.
    public static func groups(presentIn json: Data) throws -> Set<AdjustmentGroup> {
        let document = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        return groups(presentIn: Set(document.keys))
    }

    /// The same, from the keys of a document that is being decoded already.
    public static func groups(presentIn keys: Set<String>) -> Set<AdjustmentGroup> {
        Set(allCases.filter { group in group.fields.contains(where: keys.contains) })
    }
}

/// One field of `Adjustments`: its JSON name, and how to copy it.
private struct Member {
    let field: String
    let copy: (Adjustments, inout Adjustments) -> Void

    init<Value>(_ field: String, _ keyPath: WritableKeyPath<Adjustments, Value>) {
        self.field = field
        copy = { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] }
    }
}

extension Adjustments {
    /// Takes the settings of the given groups from `source`, leaving the others as they are.
    public mutating func apply(_ source: Adjustments, groups: Set<AdjustmentGroup>) {
        for group in groups { group.copy(from: source, to: &self) }
    }

    public func applying(_ source: Adjustments, groups: Set<AdjustmentGroup>) -> Adjustments {
        var result = self
        result.apply(source, groups: groups)
        return result
    }
}
