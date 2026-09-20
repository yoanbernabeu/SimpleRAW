import Catalog
import Foundation
import Testing
@testable import SimpleRAWUI

@Suite struct LibraryFiltersTests {
    @Test func theFilterButtonCountsWhatTheRowHolds() {
        var filter = PhotoFilter()
        #expect(filter.criteriaCount == 0)
        filter.text = "Lille"  // in the search field, in plain sight: not counted
        filter.album = 3  // the source, not a criterion of the bar
        #expect(filter.criteriaCount == 0)
        filter.minimumRating = 3
        filter.flags = [.picked, .none]
        filter.colorLabels = [.red]
        filter.isEdited = true
        filter.cameras = ["RICOH GR III"]
        filter.minimumISO = 1600
        filter.capturedFrom = Date(timeIntervalSince1970: 0)
        filter.capturedTo = Date(timeIntervalSince1970: 86_400)
        #expect(filter.criteriaCount == 7)
    }

    @Test func starsToggle() {
        var filter = PhotoFilter()
        filter.toggleMinimumRating(3)
        #expect(filter.minimumRating == 3)
        filter.toggleMinimumRating(4)
        #expect(filter.minimumRating == 4)
        filter.toggleMinimumRating(4)
        #expect(filter.minimumRating == 0)
    }

    /// The old segmented control could not say "unflagged", and its icon lied about it.
    @Test func flagsAreThreeIndependentToggles() {
        var filter = PhotoFilter()
        filter.toggle(Flag.none)
        #expect(filter.flags == [Flag.none])
        filter.toggle(Flag.picked)
        #expect(filter.flags == [Flag.none, .picked])
        filter.toggle(Flag.none)
        filter.toggle(Flag.picked)
        #expect(filter.flags == nil)
    }

    @Test func labelsAndCamerasToggleToo() {
        var filter = PhotoFilter()
        filter.toggle(ColorLabel.purple)
        filter.toggle(ColorLabel.red)
        #expect(filter.colorLabels == [.purple, .red])
        filter.toggle(ColorLabel.purple)
        filter.toggle(ColorLabel.red)
        #expect(filter.colorLabels == nil)

        filter.toggle(camera: "RICOH GR III")
        filter.toggle(camera: "X100V")
        #expect(filter.cameras == ["RICOH GR III", "X100V"])
        filter.toggle(camera: "RICOH GR III")
        filter.toggle(camera: "X100V")
        #expect(filter.cameras == nil)
    }

    @Test func editedOnlyIsOnOrAbsent() {
        var filter = PhotoFilter()
        filter.isEditedOnly = true
        #expect(filter.isEdited == true)
        filter.isEditedOnly = false
        #expect(filter.isEdited == nil && filter.isEmpty)
    }

    @Test func isoRangesAreAFewPlainChoices() {
        var filter = PhotoFilter()
        #expect(filter.isoRange == .any)
        filter.isoRange = .high
        #expect(filter.minimumISO == 1600 && filter.maximumISO == nil)
        filter.isoRange = .low
        #expect(filter.minimumISO == nil && filter.maximumISO == 400)
        #expect(filter.isoRange == .low)
        filter.isoRange = .any
        #expect(filter.isEmpty)
        // A range saved by hand in a smart album is none of the choices.
        filter.minimumISO = 250
        #expect(filter.isoRange == nil)
    }

    /// Capture dates are kept as the camera wrote them, as if they were UTC: "today" is the
    /// photographer's day, not Greenwich's.
    @Test func dateRangesFollowThePhotographersCalendar() throws {
        let paris = try #require(TimeZone(identifier: "Europe/Paris"))
        // 20 September 2026, 00:30 in Paris: still the 19th in UTC.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-19T22:30:00Z"))
        func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: "\(text)T00:00:00Z")! }

        var filter = PhotoFilter()
        filter.setDateRange(.today, now: now, timeZone: paris)
        #expect(filter.capturedFrom == day("2026-09-20") && filter.capturedTo == day("2026-09-21"))
        #expect(filter.dateRange(now: now, timeZone: paris) == .today)

        filter.setDateRange(.lastSevenDays, now: now, timeZone: paris)
        #expect(filter.capturedFrom == day("2026-09-14") && filter.capturedTo == day("2026-09-21"))
        filter.setDateRange(.lastThirtyDays, now: now, timeZone: paris)
        #expect(filter.capturedFrom == day("2026-08-22"))
        filter.setDateRange(.thisYear, now: now, timeZone: paris)
        #expect(filter.capturedFrom == day("2026-01-01") && filter.capturedTo == day("2027-01-01"))
        filter.setDateRange(.lastYear, now: now, timeZone: paris)
        #expect(filter.capturedFrom == day("2025-01-01") && filter.capturedTo == day("2026-01-01"))
        #expect(filter.dateRange(now: now, timeZone: paris) == .lastYear)

        filter.setDateRange(.any, now: now, timeZone: paris)
        #expect(filter.isEmpty && filter.dateRange(now: now, timeZone: paris) == .any)
    }

    @Test func thumbnailSizesAreAFewPlainChoices() {
        #expect(ThumbnailSize.allCases.map(\.points) == [120, 180, 250, 340])
        #expect(ThumbnailSize(closestTo: 180) == .medium)
        #expect(ThumbnailSize(closestTo: 233) == .large)
        #expect(ThumbnailSize(closestTo: 1000) == .extraLarge)
    }
}

@MainActor
@Suite struct FilterRowTests {
    @Test func theRowStaysOpenWhileItFiltersAndRemembersOtherwise() throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        let defaults = UserDefaults(suiteName: "simpleraw-tests-\(UUID().uuidString)")!
        let session = LibrarySession(library: sandbox.library, defaults: defaults)
        #expect(!session.showsFilters && !session.isFilterRowVisible)

        session.filter.minimumRating = 2
        #expect(session.isFilterRowVisible)
        session.clearFilter()
        #expect(!session.isFilterRowVisible)

        session.showsFilters = true
        #expect(session.isFilterRowVisible)
        #expect(LibrarySession(library: sandbox.library, defaults: defaults).showsFilters)
    }

    @Test func theCountOnlyShowsWhenItSaysSomething() async throws {
        let sandbox = try LibrarySandbox(photos: 3)
        defer { sandbox.cleanUp() }
        let session = sandbox.session
        #expect(session.filteredCountText == nil)
        session.select(session.photos[0].id)
        session.setRating(4)
        session.filter.minimumRating = 4
        await session.settle()
        #expect(session.filteredCountText == "1 of 3")
    }

    @Test func theLibraryKnowsItsCameras() throws {
        let sandbox = try LibrarySandbox(photos: 2)
        defer { sandbox.cleanUp() }
        #expect(sandbox.session.cameras == ["RICOH GR III"])
    }
}
