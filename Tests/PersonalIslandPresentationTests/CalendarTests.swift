import Combine
import Foundation
import Testing
@testable import PersonalIslandPresentation

private func calendar(_ zone: String = "America/Chicago") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

/// 2026-11-12 in Chicago, at the given local hour/minute.
private func at(_ hour: Int, _ minute: Int = 0, day: Int = 12, zone: String = "America/Chicago") -> Date {
    calendar(zone).date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false, title: String? = nil,
                   calendarID: String = "work", meeting: URL? = nil) -> AgendaEvent {
    AgendaEvent(id: id, eventIdentifier: id, title: title ?? id, start: start, end: end, isAllDay: allDay,
                calendarID: calendarID, color: [0.2, 0.4, 0.9], meetingURL: meeting)
}

// MARK: - Agenda

@Test func todayIncludesOverlappingEventsWithAllDayFirstThenByTime() {
    let events = [
        event("late", at(17), at(18)),
        event("yesterday", at(9, day: 11), at(10, day: 11)),
        event("holiday", at(0), at(0, day: 13), allDay: true),
        event("overnight", at(23, day: 11), at(1)),           // started yesterday, ends today
        event("early", at(9), at(10)),
        event("tomorrow", at(9, day: 13), at(10, day: 13)),
    ]
    let today = CalendarAgenda.today(events, now: at(12), calendar: calendar())
    #expect(today.map(\.id) == ["holiday", "overnight", "early", "late"])
}

@Test func theDayFollowsTheConfiguredTimeZone() {
    // 03:00 UTC on the 13th is still the 12th in Chicago.
    let instant = at(21)
    let chicago = CalendarAgenda.day(containing: instant, calendar: calendar())
    let tokyo = CalendarAgenda.day(containing: instant, calendar: calendar("Asia/Tokyo"))
    #expect(chicago.start == at(0))
    #expect(chicago.duration == 86_400)
    #expect(tokyo.start != chicago.start)
}

@Test func daylightSavingDaysKeepTheirRealLength() {
    // 2026-11-01 is the US fall-back day: 25 hours long in Chicago.
    let day = CalendarAgenda.day(containing: at(12, day: 1), calendar: calendar())
    #expect(day.duration == 25 * 3_600)
}

@Test func nextIsTheOngoingOrUpcomingTimedEvent() {
    let events = [
        event("allday", at(0), at(0, day: 13), allDay: true),
        event("done", at(8), at(9)),
        event("ongoing", at(11, 30), at(12, 30)),
        event("later", at(15), at(16)),
    ]
    #expect(CalendarAgenda.next(events, now: at(12))?.id == "ongoing")
    #expect(CalendarAgenda.next(events, now: at(13))?.id == "later")
    #expect(CalendarAgenda.next(events, now: at(17)) == nil)
}

@Test func refreshHappensAtTheNextBoundaryOrMidnightButNotTooSoon() {
    let cal = calendar()
    let events = [event("a", at(13), at(14))]
    #expect(CalendarAgenda.nextRefresh(events, now: at(12), calendar: cal) == at(13))
    #expect(CalendarAgenda.nextRefresh(events, now: at(13, 30), calendar: cal) == at(14))
    #expect(CalendarAgenda.nextRefresh(events, now: at(15), calendar: cal) == at(0, day: 13))
    let imminent = at(12).addingTimeInterval(5)
    #expect(CalendarAgenda.nextRefresh([event("b", imminent, at(13))], now: at(12), calendar: cal)
            == at(12).addingTimeInterval(30))
}

@Test func onlyHttpsLinksOnKnownMeetingHostsBecomeJoinLinks() {
    #expect(CalendarAgenda.meetingLink(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/123?pwd=x thanks"])
            == URL(string: "https://us02web.zoom.us/j/123?pwd=x"))
    #expect(CalendarAgenda.meetingLink(in: ["(https://meet.google.com/abc-defg-hij)"])
            == URL(string: "https://meet.google.com/abc-defg-hij"))
    #expect(CalendarAgenda.meetingLink(in: ["https://teams.microsoft.com/l/meetup-join/x"]) != nil)
    for text in ["http://zoom.us/j/1", "https://zoom.us.evil.example/j/1", "https://evilzoom.us/j/1",
                 "https://example.com/meet.google.com", "zoommtg://zoom.us/join", "no link here"] {
        #expect(CalendarAgenda.meetingLink(in: [text]) == nil, "\(text)")
    }
}

@Test func titlesAreCleanedAndBounded() {
    #expect(CalendarAgenda.cleanTitle("Stand-up\n") == "Stand-up")
    #expect(CalendarAgenda.cleanTitle(nil) == "(No title)")
    #expect(CalendarAgenda.cleanTitle("  ") == "(No title)")
    #expect(CalendarAgenda.cleanTitle(String(repeating: "a", count: 999)).count == CalendarAgenda.maximumTitleLength)
}

// MARK: - Lifecycle

@MainActor
private final class FakeCalendarPlatform {
    var access: CalendarAccess = .granted
    var grantOnRequest = true
    var holdRequest = false
    var pendingRequest: CheckedContinuation<Void, Never>?
    var calendars = [CalendarSummary(id: "work", title: "Work", source: "iCloud", color: [1, 0, 0]),
                     CalendarSummary(id: "home", title: "Home", source: "Google", color: [0, 1, 0])]
    var stored: [AgendaEvent] = [event("standup", at(9), at(9, 15)),
                                 event("dinner", at(19), at(20), calendarID: "home")]
    var fetches: [(DateInterval, Set<String>)] = []
    var requests = 0
    var handler: (@MainActor (CalendarSignal) -> Void)?
    var observations = 0
    var scheduled: [(date: Date, cancelled: () -> Bool, action: @MainActor () -> Void)] = []
    var now = at(12)

    func controller() -> CalendarController {
        CalendarController(environment: .init(
            access: { [unowned self] in self.access },
            requestAccess: { [unowned self] in
                self.requests += 1
                if self.holdRequest { await withCheckedContinuation { self.pendingRequest = $0 } }
                if self.grantOnRequest { self.access = .granted } else { self.access = .denied }
                return self.access == .granted
            },
            calendars: { [unowned self] in self.calendars },
            events: { [unowned self] window, ids in
                self.fetches.append((window, ids))
                return self.stored.filter { ids.contains($0.calendarID) && $0.end > window.start && $0.start < window.end }
            },
            observe: { [unowned self] handler in self.handler = handler; self.observations += 1; return NSObject() },
            stopObserving: { [unowned self] _ in self.handler = nil; self.observations -= 1 },
            schedule: { [unowned self] date, action in
                var cancelled = false
                self.scheduled.append((date, { cancelled }, action))
                return AnyCancellable { cancelled = true }
            },
            now: { [unowned self] in self.now },
            calendar: { calendar() }
        ))
    }
}

@Test @MainActor func startReadsTodayAndSchedulesTheNextChangeAndStopEndsEverything() async {
    let fake = FakeCalendarPlatform()
    let controller = fake.controller()
    await controller.start(askAccess: false)
    #expect(controller.status == .ready)
    #expect(controller.todayEvents.map(\.id) == ["standup", "dinner"])
    #expect(controller.nextEvent?.id == "dinner")
    #expect(fake.fetches.count == 1)
    #expect(fake.fetches[0].0.start == at(0))
    #expect(fake.fetches[0].0.end == at(0, day: 12 + CalendarAgenda.lookaheadDays))
    #expect(fake.scheduled.last?.date == at(19))

    controller.stop()
    controller.stop()
    #expect(fake.observations == 0)
    #expect(fake.scheduled.last?.cancelled() == true)
    #expect(controller.status == .off)
    #expect(controller.todayEvents.isEmpty && controller.nextEvent == nil && controller.calendars.isEmpty)

    // A timer that fires anyway, and later reloads, do nothing after stop.
    fake.scheduled.last?.action()
    controller.reload()
    #expect(fake.fetches.count == 1)
}

@Test @MainActor func accessIsRequestedOnlyWhenAskedAndOnlyOnce() async {
    let fake = FakeCalendarPlatform()
    fake.access = .notDetermined
    let controller = fake.controller()
    await controller.start(askAccess: false)
    #expect(controller.status == .needsAccess)
    #expect(fake.requests == 0)
    #expect(fake.fetches.isEmpty)

    fake.holdRequest = true
    let asking = Task { await controller.requestAccess() }
    while fake.pendingRequest == nil { await Task.yield() }
    await controller.requestAccess()
    #expect(fake.requests == 1)
    fake.pendingRequest?.resume()
    await asking.value
    #expect(controller.status == .ready)
}

@Test @MainActor func deniedRestrictedAndWriteOnlyAccessReadNothing() async {
    for access in [CalendarAccess.denied, .restricted, .writeOnly] {
        let fake = FakeCalendarPlatform()
        fake.access = access
        let controller = fake.controller()
        await controller.start(askAccess: true)
        #expect(controller.status == .denied)
        #expect(fake.fetches.isEmpty)
        #expect(fake.requests == 0)
    }
    let fake = FakeCalendarPlatform()
    fake.access = .notDetermined
    fake.grantOnRequest = false
    let controller = fake.controller()
    await controller.start(askAccess: true)
    #expect(controller.status == .denied)
}

@Test @MainActor func hiddenCalendarsAreNeverReadAndNewOnesAppear() async {
    let fake = FakeCalendarPlatform()
    let controller = fake.controller()
    controller.hiddenCalendarIDs = ["home"]
    await controller.start(askAccess: false)
    #expect(fake.fetches.last?.1 == ["work"])
    #expect(controller.todayEvents.map(\.id) == ["standup"])
    #expect(controller.nextEvent == nil)

    controller.hiddenCalendarIDs = ["home", "work"]
    #expect(controller.todayEvents.isEmpty)
    #expect(fake.fetches.count == 1)       // nothing visible: no new fetch at all

    fake.calendars.append(CalendarSummary(id: "new", title: "New", source: "iCloud", color: [0, 0, 1]))
    fake.stored.append(event("party", at(21), at(22), calendarID: "new"))
    fake.handler?(.storeChanged)
    #expect(controller.todayEvents.map(\.id) == ["party"])
}

@Test @MainActor func storeChangesWakeDayAndTimeZoneChangesReloadAndReplaceTheTimer() async {
    let fake = FakeCalendarPlatform()
    let controller = fake.controller()
    await controller.start(askAccess: false)
    for signal in [CalendarSignal.storeChanged, .woke, .dayChanged, .timeZoneChanged] {
        let before = fake.fetches.count
        let previousTimer = fake.scheduled.last
        fake.handler?(signal)
        #expect(fake.fetches.count == before + 1)
        #expect(previousTimer?.cancelled() == true)
    }
    // Firing the current timer at its boundary reloads.
    fake.now = at(19, 1)
    let before = fake.fetches.count
    fake.scheduled.last?.action()
    #expect(fake.fetches.count == before + 1)
    #expect(controller.nextEvent?.id == "dinner")   // still ongoing
}

@Test @MainActor func aStaleTimerFromAPreviousSessionIsIgnored() async {
    let fake = FakeCalendarPlatform()
    let controller = fake.controller()
    await controller.start(askAccess: false)
    let stale = fake.scheduled.last
    controller.stop()
    await controller.start(askAccess: false)
    let fetches = fake.fetches.count
    stale?.action()
    #expect(fake.fetches.count == fetches)
}

@Test @MainActor func revokedAccessClearsEventsOnTheNextChange() async {
    let fake = FakeCalendarPlatform()
    let controller = fake.controller()
    await controller.start(askAccess: false)
    #expect(!controller.todayEvents.isEmpty)
    fake.access = .denied
    fake.handler?(.storeChanged)
    #expect(controller.status == .denied)
    #expect(controller.todayEvents.isEmpty && controller.nextEvent == nil)
}

// MARK: - Empty days and what comes next

@Test func theFirstEventOnALaterDayIncludesAllDayEventsAndIgnoresToday() {
    let events = [
        event("today", at(9), at(10)),
        event("later-timed", at(9, day: 14), at(10, day: 14)),
        event("tomorrow-allday", at(0, day: 13), at(0, day: 14), allDay: true),
        event("tomorrow-timed", at(8, day: 13), at(9, day: 13)),
    ]
    #expect(CalendarAgenda.firstAfterToday(events, now: at(12), calendar: calendar())?.id == "tomorrow-allday")
    #expect(CalendarAgenda.firstAfterToday([event("today", at(9), at(10))], now: at(12), calendar: calendar()) == nil)
    // A timed "next" event can be tomorrow while there is nothing today.
    #expect(CalendarAgenda.next([event("t", at(8, day: 13), at(9, day: 13))], now: at(12))?.id == "t")
}

@Test func dayLabelsReadNaturally() {
    let cal = calendar()
    #expect(CalendarAgenda.dayLabel(for: at(18), now: at(12), calendar: cal) == "Today")
    #expect(CalendarAgenda.dayLabel(for: at(0, day: 13), now: at(23, 59), calendar: cal) == "Tomorrow")
    let weekday = CalendarAgenda.dayLabel(for: at(9, day: 16), now: at(12), calendar: cal)
    #expect(weekday == "Monday")
    let far = CalendarAgenda.dayLabel(for: at(9, day: 27), now: at(12), calendar: cal)
    #expect(far.contains("27") && far.contains("Nov"))
}

@Test @MainActor func anEmptyDayStillShowsTheNextEventUpToThirtyDaysAhead() async {
    let fake = FakeCalendarPlatform()
    fake.stored = [event("trip", at(0, day: 30), at(0, day: 31), allDay: true, calendarID: "home")]
    let controller = fake.controller()
    await controller.start(askAccess: false)
    #expect(controller.todayEvents.isEmpty)
    #expect(controller.nextEvent == nil)               // all-day is never the timed "next"
    #expect(controller.upcomingEvent?.id == "trip")

    fake.stored = []
    fake.handler?(.storeChanged)
    #expect(controller.upcomingEvent == nil)
    controller.stop()
    #expect(controller.upcomingEvent == nil)
}
