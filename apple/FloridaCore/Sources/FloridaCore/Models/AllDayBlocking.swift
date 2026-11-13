import Foundation

public enum AllDayBlocking {
    private static func automaticTripEnd(_ event: CalendarEvent) -> Date? {
        if event.allDay, event.autoBlocksDay == true, event.blockingReason == "Your trip",
           let start = event.startAt, let end = event.endAt, end.timeIntervalSince(start) >= 2 * 86_400 {
            return end.addingTimeInterval(-86_400)
        }
        return event.endAt
    }

    public static func protectedDays(for event: CalendarEvent, calendar: Calendar) -> Range<Date>? {
        guard event.allDay, let start = event.startAt,
              let end = event.blocksDay == nil ? automaticTripEnd(event) : event.endAt else { return nil }
        return AllDayDate.localDays(start: start, end: end, calendar: calendar)
    }

    public static func isEffective(_ event: CalendarEvent, calendarBlocksScheduling: Bool) -> Bool {
        event.allDay && event.isVisible && calendarBlocksScheduling
            && (event.blocksDay ?? event.autoBlocksDay ?? event.isOutOfOffice)
    }

    public static func explanation(for event: CalendarEvent) -> String {
        let reason = event.blockingReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        var automatic = reason.flatMap { $0.isEmpty ? nil : $0 }
            ?? ((event.autoBlocksDay ?? event.isOutOfOffice) ? "This event protects the day." : "This event is informational.")
        if automaticTripEnd(event) != event.endAt { automatic += " · last day open" }
        guard let manual = event.blocksDay else { return "Automatic: \(automatic)" }
        return "Manual override: \(manual ? "Blocks" : "Does not block"). Automatic: \(automatic)"
    }

    public static func events(on day: Date, from events: [CalendarEvent], calendar: Calendar) -> [CalendarEvent] {
        let day = calendar.startOfDay(for: day)
        return events.filter { event in
            protectedDays(for: event, calendar: calendar)?.contains(day) == true
        }
    }
}
