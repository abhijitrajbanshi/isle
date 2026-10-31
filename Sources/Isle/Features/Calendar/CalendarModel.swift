import AppKit
import EventKit
import IsleKit
import Observation

/// Today's upcoming events, plus a heads-up five minutes before each.
@MainActor
@Observable
final class CalendarModel {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let color: IslandColor
    }

    private(set) var upcoming: [Event] = []
    private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    /// Advances on every refresh so time-based state re-evaluates.
    private(set) var referenceDate = Date.now

    @ObservationIgnored var post: (IslandAlert) -> Void = { _ in }
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var alerted = Set<String>()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    var hasAccess: Bool { authorization == .fullAccess }

    /// Live activity: starting within 15 minutes, or begun less than 5 ago.
    func current() -> Event? {
        guard isEnabled() else { return nil }
        let now = referenceDate
        return upcoming.first {
            $0.start.timeIntervalSince(now) < 15 * 60 && now.timeIntervalSince($0.start) < 5 * 60
        }
    }

    func start() {
        // Anything that can move the next transition restarts the sleep:
        // edited events, waking from sleep, midnight, clock / time-zone changes.
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let restart: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main, using: restart)
        center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: restart)
        center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: restart)
        center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: restart)
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: restart)
        scheduleRefresh()
        if isEnabled(), authorization == .notDetermined { requestAccess() }
    }

    /// Reloads now, then sleeps until the next moment the island's state can change.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.reloadAndMeasureWait() else { return }
                try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(min(5, wait * 0.05)))
            }
        }
    }

    private func reloadAndMeasureWait() -> TimeInterval {
        reload()
        return max(1, nextTransition().timeIntervalSinceNow)
    }

    /// The next time an event enters the 15-minute window, is due its
    /// 5-minute alert, or leaves the notch; at most 30 minutes away.
    private func nextTransition() -> Date {
        let now = Date.now
        let ceiling = now.addingTimeInterval(30 * 60)
        let offsets: [TimeInterval] = [-15 * 60, -5 * 60 - 30, 5 * 60]
        let candidates: [Date] = upcoming.flatMap { event in offsets.map { event.start.addingTimeInterval($0) } }
        guard let next = candidates.filter({ $0 > now }).min() else { return ceiling }
        return min(next, ceiling)
    }

    func requestAccess() {
        if authorization == .denied || authorization == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            return
        }
        Task {
            _ = try? await store.requestFullAccessToEvents()
            authorization = EKEventStore.authorizationStatus(for: .event)
            scheduleRefresh()
        }
    }

    func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    private func reload() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        referenceDate = .now
        guard hasAccess, isEnabled() else {
            if !upcoming.isEmpty { upcoming = [] }
            return
        }
        let now = Date.now
        let horizon = Calendar.current.date(byAdding: .hour, value: 18, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: horizon, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map { Event(id: "\($0.calendarItemIdentifier)@\($0.startDate.timeIntervalSince1970)",
                         title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                         color: IslandColor($0.calendar?.color)) }
        if upcoming != events { upcoming = Array(events) }

        // only events still ahead can be alerted again; forget the rest
        alerted.formIntersection(events.map(\.id))
        for event in events where !alerted.contains(event.id) {
            let lead = event.start.timeIntervalSince(now)
            guard lead > 0, lead <= 5 * 60 + 30 else { continue }
            alerted.insert(event.id)
            post(.eventSoon(EventInfo(title: event.title, start: event.start, color: event.color)))
        }
    }

    func preview(_ events: [Event]) {
        upcoming = events
        authorization = .fullAccess
    }
}
