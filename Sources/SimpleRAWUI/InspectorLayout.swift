import Foundation
import RawEngine

/// One collapsible block of the inspector.
enum InspectorPanel: Hashable, Sendable {
    case sliders(SliderSpec.Section)
    case looks, curve, blackAndWhite, hsl, grading, mood, layers, spots, versions

    var title: String {
        switch self {
        case .sliders(let section): section.rawValue
        case .looks: "Looks"
        case .curve: "Curve"
        case .blackAndWhite: SliderSpec.Section.blackAndWhite.rawValue
        // What it does, rather than the name of the color model.
        case .hsl: "Color Mixer"
        case .grading: SliderSpec.Section.grading.rawValue
        // What a .cube file gives a picture, said the way a photographer would.
        case .mood: "Mood"
        case .layers: "Layers"
        case .spots: "Spot Removal"
        case .versions: "Versions"
        }
    }

    /// The canvas tool this panel's controls belong to, if any.
    var tool: Tool? {
        switch self {
        case .layers: .local
        case .spots: .spots
        default: nil
        }
    }

    /// Whether the panel holds settings away from neutral: what its dot says, so that edits
    /// can be found without opening everything.
    func isEdited(_ adjustments: Adjustments, _ context: SliderContext) -> Bool {
        switch self {
        case .sliders(let section):
            SliderSpec.all(in: section).contains { $0.value(adjustments, context) != $0.neutral(context) }
        // Looks and versions are things to pick from, not settings of their own.
        case .looks, .versions: false
        case .curve: !adjustments.curves.isIdentity
        case .blackAndWhite: adjustments.blackAndWhite.isEnabled
        case .hsl: !adjustments.hsl.isNeutral
        case .grading: !adjustments.grading.isNeutral
        case .mood: adjustments.lut != nil
        case .layers: !adjustments.locals.isEmpty
        case .spots: !adjustments.spots.isEmpty
        }
    }
}

/// The inspector shows one family of tools at a time, and inside it one open panel at a
/// time: few things on screen, everything two clicks away.
enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case light, color, creative, local

    var id: Self { self }

    var title: String {
        switch self {
        case .light: "Light"
        case .color: "Color"
        case .creative: "Creative"
        case .local: "Local"
        }
    }

    var systemImage: String {
        switch self {
        case .light: "sun.max"
        case .color: "paintpalette"
        case .creative: "sparkles"
        case .local: "circle.dashed"
        }
    }

    var panels: [InspectorPanel] {
        switch self {
        case .light: [.sliders(.essentials), .sliders(.light), .curve, .sliders(.detail), .sliders(.optics)]
        case .color: [.sliders(.color), .blackAndWhite, .hsl, .grading]
        case .creative: [.looks, .mood, .sliders(.effects), .versions]
        case .local: [.layers, .spots]
        }
    }

    /// The panel a tab opens on.
    var defaultPanel: InspectorPanel { panels[0] }

    func isEdited(_ adjustments: Adjustments, _ context: SliderContext) -> Bool {
        panels.contains { $0.isEdited(adjustments, context) }
    }

    /// The tab that holds the controls of a canvas tool, if it has any.
    static func tab(for tool: Tool) -> InspectorTab? {
        switch tool {
        case .local, .spots: .local
        case .whiteBalance: .color
        case .none, .crop, .level: nil
        }
    }
}

/// How the inspector and the canvas keep in step.
enum InspectorLayout {
    /// What the inspector remembers between launches. Named here rather than written where
    /// they are read: a script that puts the interface in a known state has to write the
    /// same two keys.
    static let tabKey = "inspector.tab"
    static let openPanelsKey = "inspector.openPanels"

    /// The tool the canvas should hold once `panel` is the one on screen (`nil`: none is).
    /// A panel with a tool picks it up and any other puts it down, except while a tool that
    /// has no panel is in use (crop, eyedropper): the inspector does not interrupt those.
    static func tool(whenShowing panel: InspectorPanel?, current: Tool) -> Tool {
        let panelTools = [InspectorPanel.layers, .spots].compactMap(\.tool)
        guard current == .none || panelTools.contains(current) else { return current }
        return panel?.tool ?? .none
    }
}
