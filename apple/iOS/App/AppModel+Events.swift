import FloridaKit
import Foundation

// Google events, local-first like tasks: an RSVP, an edit, a new event or a delete lands in the
// store at once (observation refreshes the agenda) and the sync client pushes it. Writes are
// refused here, with a toast, for calendars the user cannot write to; nothing waits on Google.
// No Undo: `Toast.undo` carries a `TaskUndo`, which knows only task fields.

extension AppModel {
    /// The event's calendar is one we can write to (accessRole owner or writer).
    func canEdit(_ event: CalendarEvent) -> Bool {
        calendarInfo(id: event.calendarId).map(Self.isWritable) ?? false
    }

    /// The user is an attendee (responseStatus != nil) on a calendar they can write to; the server
    /// refuses every write, RSVP included, on read-only calendars (a shared colleague's calendar
    /// carries *their* response, not ours).
    func canRespond(to event: CalendarEvent) -> Bool {
        event.responseStatus != nil && canEdit(event)
    }

    /// Calendars the user may create events in, selected ones first.
    var writableCalendars: [CalendarInfo] {
        let writable = calendars.filter(Self.isWritable)
        return writable.filter(\.selected) + writable.filter { !$0.selected }
    }

    /// A blank 30-minute event starting at `start` (rounded to the next 15 minutes) on the first
    /// writable calendar; id = lowercase UUID, googleId "", status "confirmed".
    func newEventTemplate(start: Date) -> CalendarEvent {
        let begin = Self.nextQuarterHour(from: start, calendar: calendar)
        return CalendarEvent(
            id: UUID().uuidString.lowercased(),
            calendarId: writableCalendars.first?.id ?? "",
            googleId: "",
            status: "confirmed",
            startAt: begin,
            endAt: begin.addingTimeInterval(30 * 60),
            allDay: false,
            updatedAt: Date())
    }

    func save(event: CalendarEvent) {
        guard requireEditable(event) else { return }
        write { try $0.saveEvent(event) }
    }

    /// Moves the event to `start`–`end` (stored instants: UTC midnights for an all-day event) and
    /// says where it went: "Moved to 3:00 PM", or with the day when that changed too.
    func reschedule(_ event: CalendarEvent, start: Date, end: Date) {
        guard requireEditable(event) else { return }
        let previous = storedVersion(of: event)
        var moved = previous
        moved.startAt = start
        moved.endAt = end
        guard write({ try $0.saveEvent(moved) }) else { return }
        showToast(Toast(message: "Moved to \(movedToText(moved, from: previous))", systemImage: "arrow.left.arrow.right", style: .info))
    }

    /// status is "accepted", "tentative" or "declined". The own entry in the guest list follows,
    /// so the sheet agrees with itself. No toast on success: the sheet shows the new answer.
    func respond(to event: CalendarEvent, status: String) {
        guard requireEditable(event) else { return }
        let previous = storedVersion(of: event)
        guard previous.responseStatus != status else { return }
        var updated = previous
        updated.responseStatus = status
        if var attendees = updated.attendees, let index = attendees.firstIndex(where: \.isSelf) {
            attendees[index].responseStatus = status
            updated.attendees = attendees
        }
        write { try $0.saveEvent(updated) }
    }

    /// Tombstones the event locally and queues the delete; Google removes it on push.
    func delete(event: CalendarEvent) {
        guard requireEditable(event) else { return }
        guard write({ try $0.deleteEvent(id: event.id) }) else { return }
        showToast(Toast(message: "Deleted “\(AgendaItem.event(event).title)”", systemImage: "trash.fill", style: .info))
    }

    /// The store's copy of the event (the row the view holds may be a moment old, and a declined
    /// event leaves the agenda while staying in the store).
    func storedVersion(of event: CalendarEvent) -> CalendarEvent {
        (try? database?.event(id: event.id)) ?? event
    }

    // MARK: - Helpers

    nonisolated static func isWritable(_ calendar: CalendarInfo) -> Bool {
        calendar.accessRole == "owner" || calendar.accessRole == "writer"
    }

    /// `date` moved forward to the next quarter hour (3:07 → 3:15, 3:00:30 → 3:15); a date that
    /// is exactly on one stays.
    nonisolated static func nextQuarterHour(from date: Date, calendar: Calendar) -> Date {
        let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let remainder = calendar.component(.minute, from: minuteStart) % 15
        if remainder == 0, minuteStart == date {
            return date
        }
        return calendar.date(byAdding: .minute, value: 15 - remainder, to: minuteStart) ?? minuteStart
    }

    /// `canEdit`, else the read-only toast.
    /// True when the event's calendar can be written; otherwise shows the read-only toast.
    func requireEditable(_ event: CalendarEvent) -> Bool {
        guard canEdit(event) else {
            showToast(Toast(message: "This calendar is read-only.", systemImage: "lock.fill", style: .error))
            return false
        }
        return true
    }

    /// "3:00 PM" for a move within the day, "Fri 9:00 AM" across days, "Tomorrow" for an all-day event.
    private func movedToText(_ moved: CalendarEvent, from previous: CalendarEvent) -> String {
        guard let start = moved.startAt else { return "a new time" }
        let now = Date()
        if moved.allDay {
            let day = AllDayDate.localDays(start: start, end: moved.endAt ?? start, calendar: calendar).lowerBound
            return Formatting.dayLabel(day, now: now, calendar: calendar)
        }
        if let before = previous.startAt, calendar.isDate(before, inSameDayAs: start) {
            return Formatting.time(start)
        }
        return Formatting.dayAndTime(start, now: now, calendar: calendar)
    }
}
