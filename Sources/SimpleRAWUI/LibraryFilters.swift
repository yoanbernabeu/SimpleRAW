import Catalog
import Foundation

/// What the filter row does to a `PhotoFilter`, as pure functions: the row only calls them.
extension PhotoFilter {
    /// How many criteria the filter row holds. The search text is not one of them, it is in
    /// plain sight in its field; nor is the album, which is the source.
    var criteriaCount: Int {
        [
            minimumRating > 0, flags != nil, colorLabels != nil, isEdited != nil, cameras != nil,
            minimumISO != nil || maximumISO != nil, capturedFrom != nil || capturedTo != nil,
        ].filter(\.self).count
    }

    /// "At least this many stars"; the same star again lifts the criterion.
    mutating func toggleMinimumRating(_ stars: Int) {
        minimumRating = minimumRating == stars ? 0 : stars
    }

    mutating func toggle(_ flag: Flag) {
        let toggled = (flags ?? []).symmetricDifference([flag])
        flags = toggled.isEmpty ? nil : toggled
    }

    mutating func toggle(_ label: ColorLabel) {
        let toggled = (colorLabels ?? []).symmetricDifference([label])
        colorLabels = toggled.isEmpty ? nil : toggled
    }

    mutating func toggle(camera: String) {
        let toggled = Set(cameras ?? []).symmetricDifference([camera])
        cameras = toggled.isEmpty ? nil : toggled.sorted()
    }

    /// The row never asks for "unedited only": the criterion is on, or absent.
    var isEditedOnly: Bool {
        get { isEdited == true }
        set { isEdited = newValue ? true : nil }
    }

    /// `nil` when the bounds are none of the choices, as a filter written by hand may be.
    var isoRange: ISORange? {
        get { ISORange.allCases.first { $0.bounds.minimum == minimumISO && $0.bounds.maximum == maximumISO } }
        set { (minimumISO, maximumISO) = (newValue ?? .any).bounds }
    }

    func dateRange(now: Date = Date(), timeZone: TimeZone = .current) -> DateRange? {
        DateRange.allCases.first {
            let bounds = $0.bounds(now: now, timeZone: timeZone)
            return bounds.from == capturedFrom && bounds.to == capturedTo
        }
    }

    mutating func setDateRange(_ range: DateRange, now: Date = Date(), timeZone: TimeZone = .current) {
        (capturedFrom, capturedTo) = range.bounds(now: now, timeZone: timeZone)
    }
}

enum ISORange: String, CaseIterable, Identifiable {
    case any, low, medium, high, veryHigh

    var id: Self { self }

    var title: String {
        switch self {
        case .any: "Any ISO"
        case .low: "ISO 400 and Below"
        case .medium: "ISO 400 to 1600"
        case .high: "ISO 1600 and Above"
        case .veryHigh: "ISO 6400 and Above"
        }
    }

    var bounds: (minimum: Int?, maximum: Int?) {
        switch self {
        case .any: (nil, nil)
        case .low: (nil, 400)
        case .medium: (400, 1600)
        case .high: (1600, nil)
        case .veryHigh: (6400, nil)
        }
    }
}

enum DateRange: String, CaseIterable, Identifiable {
    case any, today, lastSevenDays, lastThirtyDays, thisYear, lastYear

    var id: Self { self }

    var title: String {
        switch self {
        case .any: "Any Date"
        case .today: "Today"
        case .lastSevenDays: "Last 7 Days"
        case .lastThirtyDays: "Last 30 Days"
        case .thisYear: "This Year"
        case .lastYear: "Last Year"
        }
    }

    /// From the first instant included to the first one excluded. The catalog keeps capture
    /// dates as the camera wrote them, local time read as if it were UTC: so is "now" here.
    func bounds(now: Date, timeZone: TimeZone) -> (from: Date?, to: Date?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: now))))
        func day(_ offset: Int) -> Date? { calendar.date(byAdding: .day, value: offset, to: today) }
        func newYear(_ offset: Int) -> Date? {
            calendar.date(from: DateComponents(year: calendar.component(.year, from: today) + offset, month: 1, day: 1))
        }
        switch self {
        case .any: return (nil, nil)
        case .today: return (today, day(1))
        case .lastSevenDays: return (day(-6), day(1))
        case .lastThirtyDays: return (day(-29), day(1))
        case .thisYear: return (newYear(0), newYear(1))
        case .lastYear: return (newYear(-1), newYear(0))
        }
    }
}

/// The sizes the View menu offers. The grid keeps a number of points, so that a finer
/// control can come later without a migration.
enum ThumbnailSize: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge

    var id: Self { self }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    var points: Double {
        switch self {
        case .small: 120
        case .medium: 180
        case .large: 250
        case .extraLarge: 340
        }
    }

    init(closestTo points: Double) {
        self = Self.allCases.min { abs($0.points - points) < abs($1.points - points) } ?? .medium
    }
}
