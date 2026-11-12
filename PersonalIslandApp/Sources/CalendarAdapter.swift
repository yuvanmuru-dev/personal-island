/*
 * Personal Island — EventKit adapter (read-only).
 * Written for this personal project; no upstream file copied.
 */

import AppKit
import Combine
import EventKit

/// Real platform access for `CalendarController`. Only reads events and
/// calendars already on this Mac; never saves, removes or changes anything,
/// and never touches reminders. The event store exists only while the
/// Calendar switch is on.
@MainActor
final class CalendarAdapter {
    private var store: EKEventStore?
    /// Bounds memory and work for unusually busy calendars.
    static let maximumEvents = 500

    func environment() -> CalendarController.Environment {
        CalendarController.Environment(
            access: { Self.access() },
            requestAccess: { [weak self] in await self?.requestAccess() ?? false },
            calendars: { [weak self] in self?.calendars() ?? [] },
            events: { [weak self] window, ids in self?.events(in: window, calendarIDs: ids) ?? [] },
            observe: { [weak self] handler in
                let store = self?.activeStore() ?? EKEventStore()
                return Observation(store: store, handler: handler)
            },
            stopObserving: { [weak self] token in
                (token as? Observation)?.invalidate()
                self?.store = nil
            },
            schedule: { date, action in
                let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated { action() }
                }
                timer.tolerance = 1
                RunLoop.main.add(timer, forMode: .common)
                return AnyCancellable { timer.invalidate() }
            },
            now: { Date() },
            calendar: { Calendar.autoupdatingCurrent }
        )
    }

    static func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .writeOnly: .writeOnly
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    private func activeStore() -> EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }

    private func requestAccess() async -> Bool {
        let store = activeStore()
        return await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
        }
    }

    private func calendars() -> [CalendarSummary] {
        guard Self.access() == .granted else { return [] }
        return activeStore().calendars(for: .event)
            .map { calendar in
                CalendarSummary(
                    id: calendar.calendarIdentifier,
                    title: CalendarAgenda.cleanTitle(calendar.title),
                    source: CalendarAgenda.cleanTitle(calendar.source?.title),
                    color: Self.components(calendar.cgColor)
                )
            }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    private func events(in window: DateInterval, calendarIDs: Set<String>) -> [AgendaEvent] {
        guard Self.access() == .granted else { return [] }
        let store = activeStore()
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(Self.maximumEvents)
            .compactMap { event in
                guard let start = event.startDate, let end = event.endDate,
                      let identifier = event.eventIdentifier, end >= start else { return nil }
                return AgendaEvent(
                    id: identifier + "@" + String(Int(start.timeIntervalSince1970)),
                    eventIdentifier: identifier,
                    title: CalendarAgenda.cleanTitle(event.title),
                    start: start, end: end, isAllDay: event.isAllDay,
                    calendarID: event.calendar.calendarIdentifier,
                    color: Self.components(event.calendar.cgColor),
                    // Notes and location are read only to find a meeting link
                    // in memory; they are not displayed or kept.
                    meetingURL: CalendarAgenda.meetingLink(in: [event.url?.absoluteString, event.location, event.notes])
                )
            }
    }

    private static func components(_ color: CGColor?) -> [Double] {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return [0.6, 0.6, 0.6] }
        return parts.prefix(3).map { min(1, max(0, Double($0))) }
    }

    /// Opens the event in Apple Calendar. Explicit user action only.
    static func openInCalendar(_ event: AgendaEvent) {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":/?#")
        guard let encoded = event.eventIdentifier.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Observation

    /// Calendar database changes, day and time-zone changes, and wake.
    @MainActor
    private final class Observation: NSObject {
        private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []

        init(store: EKEventStore, handler: @escaping @MainActor (CalendarSignal) -> Void) {
            super.init()
            let center = NotificationCenter.default
            let workspace = NSWorkspace.shared.notificationCenter
            let entries: [(NotificationCenter, Notification.Name, AnyObject?, CalendarSignal)] = [
                (center, .EKEventStoreChanged, store, .storeChanged),
                (center, .NSCalendarDayChanged, nil, .dayChanged),
                (center, .NSSystemTimeZoneDidChange, nil, .timeZoneChanged),
                (workspace, NSWorkspace.didWakeNotification, nil, .woke),
            ]
            for (notificationCenter, name, object, signal) in entries {
                tokens.append((notificationCenter, notificationCenter.addObserver(forName: name, object: object, queue: .main) { _ in
                    MainActor.assumeIsolated { handler(signal) }
                }))
            }
        }

        func invalidate() {
            for (center, token) in tokens { center.removeObserver(token) }
            tokens = []
        }
    }
}
