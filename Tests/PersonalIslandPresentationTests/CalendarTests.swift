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
    #expect(fake.fetches[0].0.start == at(0, day: 1))          // from the month's start, for the grid
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


// MARK: - Month grid

private func gregorian(firstWeekday: Int) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    gregorian(firstWeekday: 1).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

@Test func theMonthStartsOnTheUsersFirstWeekday() {
    // October 1, 2026 is a Thursday.
    let sunday = CalendarAgenda.monthGrid(containing: date(10, 4), calendar: gregorian(firstWeekday: 1))
    #expect(sunday.weekdaySymbols == ["S", "M", "T", "W", "T", "F", "S"])
    #expect(sunday.weeks[0] == [nil, nil, nil, nil, 1, 2, 3])
    #expect(sunday.weekendColumns == [0, 6])
    #expect(sunday.monthName == "October" && sunday.today == 4)
    let monday = CalendarAgenda.monthGrid(containing: date(10, 4), calendar: gregorian(firstWeekday: 2))
    #expect(monday.weekdaySymbols.first == "M")
    #expect(monday.weeks[0] == [nil, nil, nil, 1, 2, 3, 4])
    #expect(monday.weekendColumns == [5, 6])
}

@Test func everyDayAppearsOnceInWholeWeeks() {
    for (month, weeks) in [(2, 4), (8, 6), (10, 5)] {               // Feb 2026 fits 4 weeks, Aug needs 6
        let grid = CalendarAgenda.monthGrid(containing: date(month, 10), calendar: gregorian(firstWeekday: 1))
        let days = grid.weeks.flatMap { $0 }.compactMap { $0 }
        #expect(grid.weeks.count == weeks && grid.weeks.allSatisfy { $0.count == 7 })
        #expect(days == Array(1...days.count))
    }
}

@Test func daysWithEventsIncludeEveryDayCoveredInThisMonthOnly() {
    let cal = gregorian(firstWeekday: 1)
    let events = [
        event("holiday", date(10, 4, 0), date(10, 5, 0), allDay: true),     // exclusive end: only the 4th
        event("trip", date(10, 30, 22), date(11, 2, 9)),                      // spills into next month
        event("overnight", date(10, 12, 23), date(10, 13, 1)),
        event("lastMonth", date(9, 20), date(9, 21)),
    ]
    #expect(CalendarAgenda.eventDays(events, inMonthOf: date(10, 4), calendar: cal) == [4, 12, 13, 30, 31])
}

@Test @MainActor func theControllerPublishesThisMonthsEventDays() async {
    let fake = FakeCalendarPlatform()
    fake.stored.append(event("earlier", at(9, day: 3), at(10, day: 3)))
    let controller = fake.controller()
    await controller.start(askAccess: false)
    #expect(controller.eventDays == [3, 12])
    #expect(controller.todayEvents.map(\.id) == ["standup", "dinner"])   // earlier days stay out of today
    controller.stop()
    #expect(controller.eventDays.isEmpty)
}

// MARK: - Picking a day

@Test func aPickedDayShowsItsOwnEventsInAgendaOrder() {
    let cal = gregorian(firstWeekday: 1)
    let events = [
        event("lunch", date(10, 20, 12), date(10, 20, 13)),
        event("fair", date(10, 20, 0), date(10, 21, 0), allDay: true),
        event("trip", date(10, 19, 22), date(10, 20, 2)),
        event("other", date(10, 22), date(10, 22, 13)),
    ]
    let picked = CalendarAgenda.events(onDay: 20, inMonthOf: date(10, 4), events, calendar: cal)
    #expect(picked.map(\.id) == ["fair", "trip", "lunch"])
    #expect(CalendarAgenda.events(onDay: 23, inMonthOf: date(10, 4), events, calendar: cal).isEmpty)
}

@Test func daysOutsideTheMonthHaveNoDate() {
    let cal = gregorian(firstWeekday: 1)
    #expect(CalendarAgenda.date(ofDay: 31, inMonthOf: date(10, 4), calendar: cal) != nil)
    #expect(CalendarAgenda.date(ofDay: 31, inMonthOf: date(11, 4), calendar: cal) == nil)   // November has 30
    #expect(CalendarAgenda.date(ofDay: 0, inMonthOf: date(10, 4), calendar: cal) == nil)
    #expect(CalendarAgenda.events(onDay: 40, inMonthOf: date(10, 4), [event("x", date(10, 4), date(10, 5))], calendar: cal).isEmpty)
}

@Test @MainActor func theControllerKeepsTheMonthsEventsForPickedDaysAndForgetsThemOnStop() async {
    let fake = FakeCalendarPlatform()
    fake.stored.append(event("earlier", at(9, day: 3), at(10, day: 3)))
    fake.stored.append(event("later", at(9, day: 20), at(10, day: 20)))
    let controller = fake.controller()
    await controller.start(askAccess: false)
    let third = CalendarAgenda.events(onDay: 3, inMonthOf: at(12), controller.monthEvents, calendar: calendar())
    #expect(third.map(\.id) == ["earlier"])
    #expect(Set(controller.monthEvents.map(\.id)) == ["standup", "dinner", "earlier", "later"])
    controller.stop()
    #expect(controller.monthEvents.isEmpty)
}

// MARK: - Other months

@Test func anotherMonthHasNoTodayAndShowsTheYearWhenItDiffers() {
    let cal = gregorian(firstWeekday: 1)
    let november = CalendarAgenda.monthGrid(containing: date(10, 4), month: date(11, 15), calendar: cal)
    #expect(november.today == nil && november.monthName == "November")
    let nextYear = CalendarAgenda.monthGrid(containing: date(10, 4), month: date(10, 4).addingTimeInterval(100 * 86_400), calendar: cal)
    #expect(nextYear.monthName == "January 2027")
    #expect(CalendarAgenda.monthGrid(containing: date(10, 4), month: date(10, 20), calendar: cal).today == 4)
}

@Test func scrollingStepsOneMonthPerSwipeOrWheelNotch() {
    var stepper = MonthScrollStepper()
    #expect(stepper.step(delta: 1, precise: false, began: false, momentum: false) == 1)     // wheel down
    #expect(stepper.step(delta: -3, precise: false, began: false, momentum: false) == -1)   // wheel up
    #expect(stepper.step(delta: 10, precise: true, began: true, momentum: false) == nil)    // swipe starts
    #expect(stepper.step(delta: 20, precise: true, began: false, momentum: false) == 1)     // enough travel
    #expect(stepper.step(delta: 80, precise: true, began: false, momentum: false) == nil)   // same swipe
    #expect(stepper.step(delta: 80, precise: true, began: false, momentum: true) == nil)    // momentum
    #expect(stepper.step(delta: -30, precise: true, began: true, momentum: false) == -1)    // a new swipe back
    #expect(stepper.step(delta: 5, precise: true, began: true, momentum: false) == nil)     // small nudge
}

@Test @MainActor func showingAnotherMonthReadsItSeparatelyAndKeepsTodaysAgenda() async {
    let fake = FakeCalendarPlatform()
    fake.stored.append(event("december", at(9, day: 10).addingTimeInterval(28 * 86_400), at(10, day: 10).addingTimeInterval(28 * 86_400)))
    let controller = fake.controller()
    await controller.start(askAccess: false)
    controller.showMonth(offset: 1)                              // December 2026
    #expect(fake.fetches.count == 3)                             // today's window, then today's + December's
    let december = fake.fetches[2].0
    #expect(december.start == calendar().date(from: DateComponents(year: 2026, month: 12, day: 1)))
    #expect(controller.eventDays == [8])
    #expect(controller.todayEvents.map(\.id) == ["standup", "dinner"])
    #expect(controller.monthOffset == 1)
    controller.showMonth(offset: 99)
    #expect(controller.monthOffset == CalendarAgenda.monthRange.upperBound)
    controller.showMonth(offset: 0)
    #expect(controller.eventDays == [12])
    controller.showMonth(offset: -2)
    controller.stop()
    #expect(controller.monthOffset == 0 && controller.shownMonth == nil)
}
