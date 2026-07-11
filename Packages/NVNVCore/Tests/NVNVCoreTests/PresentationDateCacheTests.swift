import Foundation
import NVNVCore
import Testing

@Suite("Presentation date cache")
struct PresentationDateCacheTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let locale = Locale(identifier: "en_GB")

    @Test func reusesDatesWithinOnePresentationContext() {
        let cache = PresentationDateCache()
        let date = Date(timeIntervalSince1970: 1_704_207_840)
        let now = Date(timeIntervalSince1970: 1_704_196_800)

        let first = cache.string(for: date, now: now, locale: locale, calendar: gregorian, timeZone: utc)
        let second = cache.string(for: date, now: now, locale: locale, calendar: gregorian, timeZone: utc)

        #expect(first == second)
        #expect(cache.cachedEntryCount == 1)
        #expect(cache.generation == 1)
        #expect(first == "2 Jan 2024 at 15:04")
    }

    @Test func dateChangeCreatesANewEntry() {
        let cache = PresentationDateCache()
        let now = Date(timeIntervalSince1970: 1_704_196_800)
        let firstDate = Date(timeIntervalSince1970: 1_704_207_840)
        let changedDate = firstDate.addingTimeInterval(60)

        let first = cache.string(for: firstDate, now: now, locale: locale, calendar: gregorian, timeZone: utc)
        let changed = cache.string(for: changedDate, now: now, locale: locale, calendar: gregorian, timeZone: utc)

        #expect(first != changed)
        #expect(cache.cachedEntryCount == 2)
        #expect(cache.generation == 1)
    }

    @Test func invalidatesForLocaleTimeZoneAndDayBoundary() {
        let cache = PresentationDateCache()
        let date = Date(timeIntervalSince1970: 1_704_207_840)
        let firstDay = Date(timeIntervalSince1970: 1_704_196_800)
        _ = cache.string(for: date, now: firstDay, locale: locale, calendar: gregorian, timeZone: utc)

        _ = cache.string(
            for: date,
            now: firstDay,
            locale: Locale(identifier: "en_US"),
            calendar: gregorian,
            timeZone: utc
        )
        #expect(cache.generation == 2)

        let london = TimeZone(identifier: "Europe/London")!
        _ = cache.string(for: date, now: firstDay, locale: Locale(identifier: "en_US"), calendar: gregorian, timeZone: london)
        #expect(cache.generation == 3)

        _ = cache.string(
            for: date,
            now: firstDay.addingTimeInterval(86_400),
            locale: Locale(identifier: "en_US"),
            calendar: gregorian,
            timeZone: london
        )
        #expect(cache.generation == 4)
        #expect(cache.cachedEntryCount == 1)
    }

    private var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
}
