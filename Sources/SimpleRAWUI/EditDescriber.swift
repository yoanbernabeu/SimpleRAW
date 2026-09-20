import Foundation
import RawEngine

/// Names a step of the history by looking at what changed between two states of the settings.
/// Pure: the same two documents always give the same words.
enum EditDescriber {
    static func label(from old: Adjustments, to new: Adjustments, context: SliderContext) -> String {
        var changes: [String] = []
        if old.locals != new.locals { changes.append(layers(from: old.locals, to: new.locals)) }
        if old.spots != new.spots {
            changes.append(new.spots.count > old.spots.count ? "Added Spot" : new.spots.count < old.spots.count ? "Removed Spot" : "Moved Spot")
        }
        if old.geometry != new.geometry { changes.append(geometry(from: old.geometry, to: new.geometry)) }
        if old.curves != new.curves { changes.append("Curve") }
        if old.hsl != new.hsl { changes.append("Color Mixer") }
        if old.grading.wheelsDiffer(from: new.grading) { changes.append("Color Grading") }
        if old.blackAndWhite.isEnabled != new.blackAndWhite.isEnabled { changes.append("Black & White") }

        // Geometry has words of its own above; its slider would count it twice.
        let sliders = SliderSpec.all.filter { $0.section != .geometry && $0.value(old, context) != $0.value(new, context) }
        if changes.isEmpty, sliders.count == 1, let spec = sliders.first {
            return "\(spec.title) \(formatted(spec.value(new, context), for: spec, context: context))"
        }
        let families = Set(sliders.map(\.section.rawValue))
        if !sliders.isEmpty { changes.append(families.count == 1 ? families.first ?? "Settings" : "Several Settings") }

        switch changes.count {
        case 0: return "Edit"
        case 1: return changes[0]
        // Everything went back to nothing at once: that was the Reset command.
        default: return new == Adjustments() ? "Reset" : "Several Settings"
        }
    }

    /// Signed when the slider is centered on zero, plain otherwise: "+0.35", "6500".
    private static func formatted(_ value: Double, for spec: SliderSpec, context: SliderContext) -> String {
        let number = value.formatted(.number.precision(.fractionLength(spec.fractionDigits)).grouping(.never).locale(Locale(identifier: "en_US")))
        return spec.neutral(context) == 0 && spec.range.lowerBound < 0 && value > 0 ? "+\(number)" : number
    }

    private static func geometry(from old: Geometry, to new: Geometry) -> String {
        if old.quarterTurns != new.quarterTurns { return "Rotate" }
        if old.straighten != new.straighten, old.crop == new.crop { return "Straighten" }
        return "Crop"
    }

    private static func layers(from old: [LocalAdjustment], to new: [LocalAdjustment]) -> String {
        if new.count > old.count { return "Added Mask" }
        if new.count < old.count { return "Removed Mask" }
        if old.map(\.id) != new.map(\.id) { return "Reordered Layers" }
        for (before, after) in zip(old, new) where before != after {
            if before.isEnabled != after.isEnabled { return after.isEnabled ? "Showed Layer" : "Hid Layer" }
            if before.mask != after.mask { return "Mask" }
            if before.opacity != after.opacity { return "Layer Opacity" }
            if before.name != after.name { return "Renamed Layer" }
        }
        return "Local Adjustment"
    }
}

private extension ColorGrading {
    /// The wheels, leaving out what the sliders of the panel already account for.
    func wheelsDiffer(from other: ColorGrading) -> Bool {
        var (mine, theirs) = (self, other)
        (mine.balance, theirs.balance) = (0, 0)
        return mine != theirs
    }
}
