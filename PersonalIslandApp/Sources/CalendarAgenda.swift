/*
 * Personal Island — calendar agenda model and lifecycle.
 * Written for this personal project; no upstream file copied.
 */

import Combine
import Foundation

/// One occurrence of an event, kept only in memory. Read-only: nothing here
/// can create, change or delete calendar data.
struct AgendaEvent: Equatable, Identifiable {
    /// Unique per occurrence (repeating events share an event identifier).
    let id: String
    let eventIdentifier: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    /// sRGB components 0...1, for the calendar's color dot.
    let color: [Double]
    let meetingURL: URL?
}

struct CalendarSummary: Equatable, Identifiable {
    let id: String
    let title: String
    let source: String
    let color: [Double]
}

enum CalendarAccess: Equatable { case notDetermined, granted, denied, restricted, writeOnly }

enum CalendarStatus: Equatable {
    case off
    /// macOS has not asked yet; the user can grant access from the island.
    case needsAccess
    /// Denied, restricted, or write-only access that cannot read events.
    case denied
    case ready
}

enum CalendarSignal { case storeChanged, dayChanged, woke, timeZoneChanged }

/// The month around today, laid out in weeks starting on the user's first
/// weekday. Days outside the month are nil.
struct MonthGrid: Equatable {
    let monthName: String
    /// Very short weekday symbols in display order, e.g. "S M T W T F S".
    let weekdaySymbols: [String]
    /// Weekday columns that fall on the weekend, for dimming.
    let weekendColumns: Set<Int>
    let weeks: [[Int?]]
    /// Today's day of the month, or nil when showing another month.
    let today: Int?
}

/// Turns scrolling into one-month steps: each mouse-wheel notch is a step;
/// a trackpad swipe steps once after enough travel and ignores the rest of
/// the gesture, including its momentum.
struct MonthScrollStepper {
    /// Trackpad travel, in points, that counts as one step.
    static let threshold: Double = 24
    private var accumulated: Double = 0
    private var steppedInGesture = false

    /// `delta` is positive for forward (scrolling down or swiping left).
    /// Returns +1 or -1 when the shown month should change.
    mutating func step(delta: Double, precise: Bool, began: Bool, momentum: Bool) -> Int? {
        guard precise else { return delta == 0 ? nil : (delta > 0 ? 1 : -1) }
        if began {
            accumulated = 0
            steppedInGesture = false
        }
        if momentum || steppedInGesture { return nil }
        accumulated += delta
        guard abs(accumulated) >= Self.threshold else { return nil }
        steppedInGesture = true
        return accumulated > 0 ? 1 : -1
    }
}

enum CalendarAgenda {
    /// How far ahead to look for the next event.
    static let lookaheadDays = 30
    static let maximumTitleLength = 200

    /// The local day containing `now`.
    static func day(containing now: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// Today's events: all-day first, then by start time, then title.
    static func today(_ events: [AgendaEvent], now: Date, calendar: Calendar) -> [AgendaEvent] {
        let day = day(containing: now, calendar: calendar)
        return events
            .filter { $0.start < day.end && $0.end > day.start }
            .sorted(by: order)
    }

    /// The ongoing or next timed event; all-day events are not "next".
    static func next(_ events: [AgendaEvent], now: Date) -> AgendaEvent? {
        events.filter { !$0.isAllDay && $0.end > now }.min(by: order)
    }

    /// The first event on a later day, timed or all-day, for showing what is
    /// coming when today is empty or finished. Same-day ties put all-day first.
    static func firstAfterToday(_ events: [AgendaEvent], now: Date, calendar: Calendar) -> AgendaEvent? {
        let end = day(containing: now, calendar: calendar).end
        return events.filter { $0.start >= end }.min(by: order)
    }

    /// How far from the current month the grid can be scrolled.
    static let monthRange = -12...12

    /// The month containing `now` (or `month` when given) as a grid of day
    /// numbers; today is marked only in its own month.
    static func monthGrid(containing now: Date, month shown: Date? = nil, calendar: Calendar) -> MonthGrid {
        let current = now
        let today = calendar.isDate(shown ?? now, equalTo: current, toGranularity: .month)
            ? calendar.component(.day, from: current) : nil
        let now = shown ?? now
        let month = calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 86_400)
        let dayCount = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let firstWeekday = calendar.component(.weekday, from: month.start)           // 1 = Sunday
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells: [Int?] = Array(repeating: nil, count: leading) + (1...dayCount).map { Optional($0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        // Columns whose weekday is a weekend day in this calendar.
        var weekend = Set<Int>()
        for column in 0..<7 {
            let weekday = (calendar.firstWeekday - 1 + column) % 7 + 1
            var components = DateComponents()
            components.weekday = weekday
            if let date = calendar.nextDate(after: month.start, matching: components, matchingPolicy: .nextTime),
               calendar.isDateInWeekend(date) { weekend.insert(column) }
        }
        var style = Date.FormatStyle.dateTime.month(.wide)
        style.timeZone = calendar.timeZone
        style.calendar = calendar
        if !calendar.isDate(now, equalTo: current, toGranularity: .year) {
            // A month in another year shows the year too.
            style = style.year()
        }
        return MonthGrid(monthName: now.formatted(style), weekdaySymbols: ordered, weekendColumns: weekend,
                         weeks: weeks, today: today)
    }

    /// Events on a given day of `now`'s month, ordered like today's agenda;
    /// empty for a day that does not exist in that month.
    static func events(onDay day: Int, inMonthOf now: Date, _ events: [AgendaEvent], calendar: Calendar) -> [AgendaEvent] {
        guard let date = date(ofDay: day, inMonthOf: now, calendar: calendar) else { return [] }
        return today(events, now: date, calendar: calendar)
    }

    /// Noon on that day of the month (noon avoids daylight-saving edges).
    static func date(ofDay day: Int, inMonthOf now: Date, calendar: Calendar) -> Date? {
        guard let range = calendar.range(of: .day, in: .month, for: now), range.contains(day) else { return nil }
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = day
        components.hour = 12
        return calendar.date(from: components)
    }

    /// Days of `now`'s month that have at least one event (multi-day events
    /// mark every day they cover; an all-day event's end is exclusive).
    static func eventDays(_ events: [AgendaEvent], inMonthOf now: Date, calendar: Calendar) -> Set<Int> {
        guard let month = calendar.dateInterval(of: .month, for: now) else { return [] }
        var days = Set<Int>()
        for event in events where event.end > month.start && event.start < month.end {
            var day = calendar.startOfDay(for: max(event.start, month.start))
            let last = min(event.end, month.end)
            while day < last, days.count < 31 {
                days.insert(calendar.component(.day, from: day))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days
    }

    /// "Tomorrow", a weekday within the coming week, or a short date.
    static func dayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
        var style = Date.FormatStyle.dateTime
        style.timeZone = calendar.timeZone
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2..<7: return date.formatted(style.weekday(.wide))
        default: return date.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    /// When the displayed agenda can next change on its own: the next start
    /// or end, or midnight. Never sooner than 30 seconds from now.
    static func nextRefresh(_ events: [AgendaEvent], now: Date, calendar: Calendar) -> Date {
        let midnight = day(containing: now, calendar: calendar).end
        let boundaries = events.flatMap { [$0.start, $0.end] }.filter { $0 > now }
        let soonest = min(boundaries.min() ?? midnight, midnight)
        return max(soonest, now.addingTimeInterval(30))
    }

    /// The first video-meeting link among the candidates (event URL,
    /// location, notes). Only https links on known meeting hosts qualify, so
    /// arbitrary links in notes are never offered as "Join".
    static func meetingLink(in candidates: [String?]) -> URL? {
        for text in candidates.compactMap({ $0 }) {
            let pattern = /https:\/\/[^\s<>"')\]]+/
            for match in text.matches(of: pattern) {
                guard let url = URL(string: String(match.output)), let host = url.host?.lowercased(),
                      url.scheme == "https", isMeetingHost(host) else { continue }
                return url
            }
        }
        return nil
    }

    static func isMeetingHost(_ host: String) -> Bool {
        let exact = ["meet.google.com", "teams.microsoft.com", "teams.live.com", "facetime.apple.com"]
        let suffixes = ["zoom.us", "webex.com", "whereby.com"]
        return exact.contains(host) || suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Removes control characters and bounds length; empty becomes "(No title)".
    static func cleanTitle(_ title: String?) -> String {
        let scalars = (title ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "(No title)" : String(trimmed.prefix(maximumTitleLength))
    }

    private static func order(_ a: AgendaEvent, _ b: AgendaEvent) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.start != b.start { return a.start < b.start }
        if a.title != b.title { return a.title < b.title }
        return a.id < b.id
    }
}

/// Starts and stops all calendar work for the feature switch. Platform
/// access is injected so tests never touch EventKit or ask for permission.
@MainActor
final class CalendarController {
    struct Environment {
        var access: @MainActor () -> CalendarAccess
        /// Shows the system Calendar prompt; true if full access was granted.
        var requestAccess: @MainActor () async -> Bool
        var calendars: @MainActor () -> [CalendarSummary]
        var events: @MainActor (DateInterval, Set<String>) -> [AgendaEvent]
        var observe: @MainActor (_ handler: @escaping @MainActor (CalendarSignal) -> Void) -> AnyObject
        var stopObserving: @MainActor (AnyObject) -> Void
        var schedule: @MainActor (Date, @escaping @MainActor () -> Void) -> AnyCancellable
        var now: @MainActor () -> Date
        var calendar: @MainActor () -> Calendar
    }

    private(set) var status: CalendarStatus = .off
    private(set) var calendars: [CalendarSummary] = []
    private(set) var todayEvents: [AgendaEvent] = []
    private(set) var nextEvent: AgendaEvent?
    /// The first event on a later day (timed or all-day), within the lookahead.
    private(set) var upcomingEvent: AgendaEvent?
    /// Days of this month with events, for the month grid.
    private(set) var eventDays: Set<Int> = []
    /// Every event read for the shown month, so any of its days can be
    /// shown. Memory only.
    private(set) var monthEvents: [AgendaEvent] = []
    /// Months from the current one shown in the grid (0 = this month).
    private(set) var monthOffset = 0
    /// A date in the shown month.
    private(set) var shownMonth: Date?
    private var publishedOffset = 0
    var onChange: (@MainActor () -> Void)?
    /// Calendars the user hid. New calendars appear by default.
    var hiddenCalendarIDs: Set<String> = [] {
        didSet { if hiddenCalendarIDs != oldValue { reload() } }
    }

    private let environment: Environment
    private var observation: AnyObject?
    private var timer: AnyCancellable?
    private var generation = 0
    private var accessRequestInFlight = false

    var isActive: Bool { observation != nil }

    init(environment: Environment) {
        self.environment = environment
    }

    func start(askAccess: Bool) async {
        guard observation == nil else { return }
        generation += 1
        observation = environment.observe { [weak self] signal in self?.reload() }
        if askAccess, environment.access() == .notDetermined {
            await requestAccess()
        } else {
            reload()
        }
    }

    /// Ends observation and the refresh timer and forgets all events.
    func stop() {
        guard let observation else { return }
        environment.stopObserving(observation)
        self.observation = nil
        timer?.cancel()
        timer = nil
        generation += 1
        accessRequestInFlight = false
        status = .off
        calendars = []
        todayEvents = []
        nextEvent = nil
        upcomingEvent = nil
        eventDays = []
        monthEvents = []
        monthOffset = 0
        publishedOffset = 0
        shownMonth = nil
        onChange?()
    }

    /// Asks macOS for Calendar access (only shows a prompt the first time).
    func requestAccess() async {
        guard observation != nil, !accessRequestInFlight else { return }
        let session = generation
        accessRequestInFlight = true
        _ = await environment.requestAccess()
        accessRequestInFlight = false
        guard session == generation else { return }
        reload()
    }

    /// Shows another month in the grid, relative to the current one; its
    /// events are read only while it is shown.
    func showMonth(offset: Int) {
        let clamped = min(max(offset, CalendarAgenda.monthRange.lowerBound), CalendarAgenda.monthRange.upperBound)
        guard clamped != monthOffset else { return }
        monthOffset = clamped
        reload()
    }

    /// Re-reads calendars and events and schedules the next automatic update.
    func reload() {
        guard observation != nil else { return }
        timer?.cancel()
        timer = nil
        switch environment.access() {
        case .notDetermined:
            publish(.needsAccess, calendars: [], today: [], next: nil, upcoming: nil, days: [], all: [])
            return
        case .denied, .restricted, .writeOnly:
            publish(.denied, calendars: [], today: [], next: nil, upcoming: nil, days: [], all: [])
            return
        case .granted:
            break
        }
        let now = environment.now()
        let calendar = environment.calendar()
        let all = environment.calendars()
        let visible = Set(all.map(\.id)).subtracting(hiddenCalendarIDs)
        let day = CalendarAgenda.day(containing: now, calendar: calendar)
        let horizon = calendar.date(byAdding: .day, value: CalendarAgenda.lookaheadDays, to: day.start)
            ?? day.start.addingTimeInterval(Double(CalendarAgenda.lookaheadDays) * 86_400)
        // From the start of the month, so the month grid can mark earlier days.
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? day.start
        let window = DateInterval(start: min(day.start, monthStart), end: max(day.end, horizon))
        let events = visible.isEmpty ? [] : environment.events(window, visible)
        let today = CalendarAgenda.today(events, now: now, calendar: calendar)
        // Another month in the grid is read separately, so today's agenda
        // and the lookahead are never crowded out.
        let shown = calendar.date(byAdding: .month, value: monthOffset, to: now) ?? now
        var monthEvents = events
        if monthOffset != 0, !visible.isEmpty, let month = calendar.dateInterval(of: .month, for: shown) {
            monthEvents = environment.events(month, visible)
        }
        shownMonth = shown
        publish(.ready, calendars: all, today: today, next: CalendarAgenda.next(events, now: now),
                upcoming: CalendarAgenda.firstAfterToday(events, now: now, calendar: calendar),
                days: CalendarAgenda.eventDays(monthEvents, inMonthOf: shown, calendar: calendar), all: monthEvents,
                force: monthOffset != publishedOffset)
        publishedOffset = monthOffset
        let session = generation
        timer = environment.schedule(CalendarAgenda.nextRefresh(events, now: now, calendar: calendar)) { [weak self] in
            guard let self, session == self.generation else { return }
            self.reload()
        }
    }

    private func publish(_ status: CalendarStatus, calendars: [CalendarSummary], today: [AgendaEvent],
                         next: AgendaEvent?, upcoming: AgendaEvent?, days: Set<Int>, all: [AgendaEvent],
                         force: Bool = false) {
        guard force || status != self.status || calendars != self.calendars || today != todayEvents
                || next != nextEvent || upcoming != upcomingEvent || days != eventDays || all != monthEvents else { return }
        eventDays = days
        monthEvents = all
        self.status = status
        self.calendars = calendars
        todayEvents = today
        nextEvent = next
        upcomingEvent = upcoming
        onChange?()
    }
}
