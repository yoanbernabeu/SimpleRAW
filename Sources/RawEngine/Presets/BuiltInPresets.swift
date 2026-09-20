import Foundation

extension Preset {
    /// Looks that ship with the app. Users can shadow any of them by saving a preset under
    /// the same name.
    public static let builtIns: [Preset] = [cameraMatch, blackAndWhite, softFade, tealAndOrange]

    /// Closes the gap between Apple's neutral rendering and the camera's own JPEG. Fitted on
    /// Ricoh GR III files (brightness, contrast and saturation of the embedded previews):
    /// it divides the average difference by more than three.
    private static let cameraMatch: Preset = {
        var adjustments = Adjustments()
        adjustments.exposure = 0.4
        adjustments.contrast = -10
        adjustments.saturation = -20
        return Preset(name: "Camera match", capturing: adjustments, groups: [.light, .color])
    }()

    private static let blackAndWhite: Preset = {
        var adjustments = Adjustments()
        // A touch of red filter: skies deepen, skin and brick lift.
        adjustments.blackAndWhite.isEnabled = true
        adjustments.blackAndWhite.red = 20
        adjustments.blackAndWhite.blue = -25
        adjustments.curves.rgb = Curve(points: [
            .init(x: 0, y: 0), .init(x: 0.25, y: 0.2), .init(x: 0.75, y: 0.82), .init(x: 1, y: 1),
        ])
        return Preset(name: "Black & white", capturing: adjustments, groups: [.color, .curve])
    }()

    private static let softFade: Preset = {
        var adjustments = Adjustments()
        adjustments.curves.rgb = Curve(points: [
            .init(x: 0, y: 0.07), .init(x: 0.25, y: 0.25), .init(x: 0.75, y: 0.77), .init(x: 1, y: 0.95),
        ])
        return Preset(name: "Soft fade", capturing: adjustments, groups: [.curve])
    }()

    private static let tealAndOrange: Preset = {
        var adjustments = Adjustments()
        adjustments.grading[.shadows] = ColorWheel(hue: 205, saturation: 35)
        adjustments.grading[.highlights] = ColorWheel(hue: 38, saturation: 30)
        return Preset(name: "Teal & orange", capturing: adjustments, groups: [.grading])
    }()
}

/// Where presets live on this Mac.
public enum PresetLibrary {
    public static let presets = JSONFileStore<Preset>.applicationSupport("Presets", builtIns: Preset.builtIns)
    public static let exportPresets = JSONFileStore<ExportPreset>.applicationSupport("Export Presets", builtIns: ExportPreset.builtIns)
}
