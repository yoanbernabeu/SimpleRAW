import CoreGraphics
import Foundation

/// How shooting parameters are written for people, shared by every front end.
public enum ExposureFormat {
    /// What stands for a value that is none: these numbers are read from files, and a shutter
    /// speed of zero once made `Int(1 / 0)`, which traps.
    public static let missing = "—"

    public static func shutterSpeed(_ seconds: Double, locale: Locale = .current) -> String {
        guard seconds.isFinite, seconds > 0 else { return missing }
        guard seconds < 1 else { return "\(seconds.formatted(.number.locale(locale))) s" }
        guard let denominator = Int(exactly: (1 / seconds).rounded()) else { return missing }
        return "1/\(denominator) s"
    }

    /// "6000 × 4000".
    public static func dimensions(_ size: CGSize) -> String {
        guard let width = Int(exactly: Double(size.width).rounded()), let height = Int(exactly: Double(size.height).rounded()) else { return missing }
        return "\(width) × \(height)"
    }

    public static func kelvins(_ temperature: Double) -> String {
        Int(exactly: temperature.rounded()).map { "\($0) K" } ?? missing
    }

    public static func aperture(_ fNumber: Double, locale: Locale = .current) -> String {
        "f/\(fNumber.formatted(.number.precision(.fractionLength(0...1)).locale(locale)))"
    }

    public static func focalLength(_ millimeters: Double, locale: Locale = .current) -> String {
        "\(millimeters.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) mm"
    }

    public static func iso(_ value: Int) -> String {
        "ISO \(value)"
    }
}
