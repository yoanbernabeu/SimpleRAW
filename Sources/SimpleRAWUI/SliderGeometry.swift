import Foundation

/// The arithmetic of a slider: from a place on the track, a key or typed text to a value.
/// Shares are fractions of the track, 0 at its left end.
enum SliderGeometry {
    /// Share of the range within which a drag snaps to neutral.
    static let snapShare = 0.012

    static func value(atShare share: Double, range: ClosedRange<Double>, neutral: Double, step: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        let proposed = range.lowerBound + min(max(share, 0), 1) * span
        if abs(proposed - neutral) < span * snapShare { return neutral }
        return rounded(proposed, to: step, in: range)
    }

    static func share(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    static func nudged(_ value: Double, bySteps steps: Double, range: ClosedRange<Double>, step: Double) -> Double {
        rounded(value + steps * step, to: step, in: range)
    }

    /// A relative drag, for fine work: the knob moves `sensitivity` times what the pointer does.
    static func value(from start: Double, draggedByShare share: Double, range: ClosedRange<Double>, step: Double, sensitivity: Double) -> Double {
        rounded(start + share * sensitivity * (range.upperBound - range.lowerBound), to: step, in: range)
    }

    /// What was typed in place of the value: a number, with a point or a comma.
    static func parsed(_ text: String, range: ClosedRange<Double>) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(cleaned), number.isFinite else { return nil }
        return min(max(number, range.lowerBound), range.upperBound)
    }

    private static func rounded(_ value: Double, to step: Double, in range: ClosedRange<Double>) -> Double {
        let snapped = step > 0 ? (value / step).rounded() * step : value
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}
