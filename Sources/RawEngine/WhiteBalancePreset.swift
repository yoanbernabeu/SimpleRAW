import Foundation

/// The lights a photographer names: a starting point that the two sliders then refine.
public enum WhiteBalancePreset: String, CaseIterable, Identifiable, Sendable {
    case asShot = "As Shot"
    case daylight = "Daylight"
    case cloudy = "Cloudy"
    case shade = "Shade"
    case tungsten = "Tungsten"
    case fluorescent = "Fluorescent"
    case flash = "Flash"

    public var id: Self { self }

    /// `nil` for As Shot: whatever the camera chose.
    public var whiteBalance: WhiteBalance? {
        switch self {
        case .asShot: nil
        case .daylight: WhiteBalance(temperature: 5500, tint: 10)
        case .cloudy: WhiteBalance(temperature: 6500, tint: 10)
        case .shade: WhiteBalance(temperature: 7500, tint: 10)
        case .tungsten: WhiteBalance(temperature: 2850, tint: 0)
        case .fluorescent: WhiteBalance(temperature: 3800, tint: 21)
        case .flash: WhiteBalance(temperature: 5500, tint: 0)
        }
    }

    public func apply(to adjustments: inout Adjustments, asShot: WhiteBalance) {
        guard let whiteBalance else {
            adjustments.whiteBalance = nil
            return
        }
        adjustments.setTemperature(whiteBalance.temperature, asShot: asShot)
        adjustments.setTint(whiteBalance.tint, asShot: asShot)
    }

    /// The preset the settings correspond to, if any: what the menu shows as selected.
    public static func matching(_ adjustments: Adjustments) -> WhiteBalancePreset? {
        guard let current = adjustments.whiteBalance else { return .asShot }
        return allCases.first { $0.whiteBalance == current }
    }
}
