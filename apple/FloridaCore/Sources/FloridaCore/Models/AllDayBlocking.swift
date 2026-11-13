import Foundation

public enum AllDayBlocking {
    public static func isEffective(_ event: CalendarEvent, calendarBlocksScheduling: Bool) -> Bool {
        event.allDay && event.isVisible && calendarBlocksScheduling
            && (event.blocksDay ?? event.autoBlocksDay ?? event.isOutOfOffice)
    }

    public static func explanation(for event: CalendarEvent) -> String {
        let reason = event.blockingReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let automatic = reason.flatMap { $0.isEmpty ? nil : $0 }
            ?? ((event.autoBlocksDay ?? event.isOutOfOffice) ? "This event protects the day." : "This event is informational.")
        guard let manual = event.blocksDay else { return "Automatic: \(automatic)" }
        return "Manual override: \(manual ? "Blocks" : "Does not block"). Automatic: \(automatic)"
    }

    public static func events(on day: Date, from events: [CalendarEvent], calendar: Calendar) -> [CalendarEvent] {
        let day = calendar.startOfDay(for: day)
        return events.filter { event in
            guard event.allDay, let start = event.startAt, let end = event.endAt else { return false }
            return AllDayDate.localDays(start: start, end: end, calendar: calendar).contains(day)
        }
    }
}
