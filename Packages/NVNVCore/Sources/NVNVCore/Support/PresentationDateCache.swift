import Foundation

/// Reuses presentation-ready date strings while the user's formatting context is stable.
///
/// The cache is safe to share between views. Changing the locale, calendar, time zone, or
/// crossing a local day boundary starts a fresh generation. Dates themselves are cache keys,
/// so an edited note with a new timestamp cannot reuse its old string.
public final class PresentationDateCache: @unchecked Sendable {
    public static let shared = PresentationDateCache()

    private struct Context: Equatable {
        let localeIdentifier: String
        let calendarIdentifier: String
        let timeZoneIdentifier: String
        let localDayStart: Date
    }

    private let lock = NSLock()
    private var context: Context?
    private var formatter: DateFormatter?
    private var entries: [Date: String] = [:]
    private var generationValue = 0
    private let maximumEntryCount = 50_000

    public init() {}

    public func string(
        for date: Date,
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        calendar suppliedCalendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var calendar = suppliedCalendar
        calendar.timeZone = timeZone
        let nextContext = Context(
            localeIdentifier: locale.identifier,
            calendarIdentifier: String(describing: calendar.identifier),
            timeZoneIdentifier: timeZone.identifier,
            localDayStart: calendar.startOfDay(for: now)
        )

        lock.lock()
        defer { lock.unlock() }

        if context != nextContext || formatter == nil {
            let nextFormatter = DateFormatter()
            nextFormatter.locale = locale
            nextFormatter.calendar = calendar
            nextFormatter.timeZone = timeZone
            nextFormatter.dateStyle = .medium
            nextFormatter.timeStyle = .short
            context = nextContext
            formatter = nextFormatter
            entries.removeAll(keepingCapacity: true)
            generationValue += 1
        }

        if let cached = entries[date] { return cached }
        if entries.count >= maximumEntryCount {
            entries.removeAll(keepingCapacity: true)
        }
        let formatted = formatter!.string(from: date)
        entries[date] = formatted
        return formatted
    }

    /// Exposed for diagnostics and deterministic cache-behavior tests.
    public var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Increases whenever presentation context invalidates all cached strings.
    public var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }
}
