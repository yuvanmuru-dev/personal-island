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

    /// Re-reads calendars and events and schedules the next automatic update.
    func reload() {
        guard observation != nil else { return }
        timer?.cancel()
        timer = nil
        switch environment.access() {
        case .notDetermined:
            publish(.needsAccess, calendars: [], today: [], next: nil, upcoming: nil)
            return
        case .denied, .restricted, .writeOnly:
            publish(.denied, calendars: [], today: [], next: nil, upcoming: nil)
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
        let window = DateInterval(start: day.start, end: max(day.end, horizon))
        let events = visible.isEmpty ? [] : environment.events(window, visible)
        let today = CalendarAgenda.today(events, now: now, calendar: calendar)
        publish(.ready, calendars: all, today: today, next: CalendarAgenda.next(events, now: now),
                upcoming: CalendarAgenda.firstAfterToday(events, now: now, calendar: calendar))
        let session = generation
        timer = environment.schedule(CalendarAgenda.nextRefresh(events, now: now, calendar: calendar)) { [weak self] in
            guard let self, session == self.generation else { return }
            self.reload()
        }
    }

    private func publish(_ status: CalendarStatus, calendars: [CalendarSummary], today: [AgendaEvent],
                         next: AgendaEvent?, upcoming: AgendaEvent?) {
        guard status != self.status || calendars != self.calendars || today != todayEvents
                || next != nextEvent || upcoming != upcomingEvent else { return }
        self.status = status
        self.calendars = calendars
        todayEvents = today
        nextEvent = next
        upcomingEvent = upcoming
        onChange?()
    }
}
