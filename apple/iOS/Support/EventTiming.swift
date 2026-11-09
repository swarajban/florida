import FloridaKit
import Foundation

/// Date math for showing an event. Timed events are instants shown in the user's calendar.
/// All-day events are stored by the server as UTC midnights with an exclusive end
/// (`2026-11-09T00:00Z ..< 2026-11-10T00:00Z` for one day), so their dates are read in UTC.
enum EventTiming {
    static let utc = TimeZone(identifier: "UTC") ?? .gmt

    /// The local days the event covers, first and last (inclusive), as local midnights.
    static func days(of event: CalendarEvent, calendar: Calendar) -> (first: Date, last: Date)? {
        guard let start = event.startAt, let end = event.endAt else { return nil }
        if event.allDay {
            var utcCalendar = calendar
            utcCalendar.timeZone = utc
            let first = utcCalendar.dateComponents([.year, .month, .day], from: start)
            let last = utcCalendar.dateComponents([.year, .month, .day], from: max(start, end.addingTimeInterval(-1)))
            guard let firstDay = calendar.date(from: first), let lastDay = calendar.date(from: last) else { return nil }
            return (firstDay, lastDay)
        }
        return (calendar.startOfDay(for: start), calendar.startOfDay(for: max(start, end.addingTimeInterval(-1))))
    }

    /// "Day 2 of 3" on a day inside a multi-day event; nil for an event within one day.
    static func continuation(of event: CalendarEvent, on day: Date, calendar: Calendar) -> String? {
        guard let span = days(of: event, calendar: calendar) else { return nil }
        let (first, last) = span
        let count = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        guard count > 1 else { return nil }
        let index = (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: day)).day ?? 0) + 1
        return "Day \(min(max(index, 1), count)) of \(count)"
    }

    /// "Monday, November 9", "Mon, Nov 9 – Wed, Nov 11" (all day); "Monday, November 9 ·
    /// 9:00 – 9:30 AM"; "Mon, Nov 9, 9:00 PM – Tue, Nov 10, 1:00 AM" (timed across midnight).
    static func text(for event: CalendarEvent, calendar: Calendar) -> String {
        guard let start = event.startAt, let end = event.endAt, let span = days(of: event, calendar: calendar)
        else { return "No time" }
        let (first, last) = span
        let fullDay = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.wide).day()
        let shortDay = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
        if event.allDay {
            if first == last {
                return first.formatted(fullDay)
            }
            return "\(first.formatted(shortDay)) – \(last.formatted(shortDay))"
        }
        if first == last {
            return "\(start.formatted(fullDay)) · \(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        let dayAndTime = shortDay.hour().minute()
        return "\(start.formatted(dayAndTime)) – \(end.formatted(dayAndTime))"
    }

    /// The Join button's title: "Join", or "Join · 1:42" from two minutes before the start.
    static func joinTitle(start: Date?, now: Date) -> String {
        guard let seconds = secondsToStart(start: start, now: now) else { return "Join" }
        return "Join · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// Whole seconds until `start` when it is at most two minutes away, else nil.
    static func secondsToStart(start: Date?, now: Date) -> Int? {
        guard let start else { return nil }
        let remaining = start.timeIntervalSince(now)
        guard remaining > 0, remaining <= 120 else { return nil }
        return Int(remaining.rounded(.up))
    }

    /// The user's own RSVP in words.
    static func responseText(_ status: String?) -> String {
        switch status {
        case "accepted": "Going"
        case "declined": "Declined"
        case "tentative": "Maybe"
        case "needsAction": "Not answered"
        case .some(let other): other
        case nil: "No response needed"
        }
    }

    /// SF Symbol for an RSVP status.
    static func responseSymbol(_ status: String?) -> String {
        switch status {
        case "accepted": "checkmark.circle.fill"
        case "declined": "xmark.circle.fill"
        case "tentative": "questionmark.circle.fill"
        default: "circle.dashed"
        }
    }
}
