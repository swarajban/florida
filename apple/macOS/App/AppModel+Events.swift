import FloridaKit
import Foundation

// Google events, local-first like tasks: an RSVP, an edit, a new event or a delete lands in the
// store at once (the live query redraws the calendar) and a background sync pushes it. Writes are
// refused here, with a status message, for calendars the user cannot write to; nothing waits on
// Google. No undo: `UndoEntry` knows only task fields, so a delete asks first instead.

/// What the event editor sheet is open on: a stored event, or the draft of a new one.
struct EventEditorRequest: Identifiable, Equatable {
    var id: String { event.id }
    let event: CalendarEvent
    let isNew: Bool
}

extension AppModel {
    /// The event's calendar is one we can write to (accessRole owner or writer).
    func canEdit(_ event: CalendarEvent) -> Bool {
        calendarsById[event.calendarId].map(Self.isWritable) ?? false
    }

    /// The user is a guest (responseStatus != nil) on a calendar they can write to; the server
    /// refuses every write, RSVP included, on read-only calendars (a shared colleague's calendar
    /// carries *their* response, not ours).
    func canRespond(to event: CalendarEvent) -> Bool {
        event.responseStatus != nil && canEdit(event)
    }

    /// Writable calendars in the preferred new-event order; the first is the default.
    var writableCalendars: [CalendarInfo] {
        calendars.filter(Self.isWritable).sorted(by: CalendarInfo.isPreferredForNewEvents)
    }

    /// The event the event keys act on: the one whose detail popover is open, else the selected one.
    var commandEvent: CalendarEvent? {
        if let id = eventDetailID, let event = events.first(where: { $0.id == id }) {
            return event
        }
        return selectedEvent
    }

    // MARK: - Commands

    /// ⇧C / `>New event`: the editor on a blank 30-minute event. Without `start` it begins at the
    /// next quarter hour when the highlighted day is today, else at 9:00 on that day.
    func openNewEventEditor(start: Date? = nil) {
        guard !writableCalendars.isEmpty else {
            statusMessage = "No calendar you can add events to — connect a Google account on the server, then sync"
            return
        }
        let fallback = calendar.isDateInToday(selectedDay)
            ? Date()
            : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDay) ?? selectedDay
        eventDetailID = nil
        eventEditor = EventEditorRequest(event: newEventTemplate(start: start ?? fallback), isNew: true)
    }

    /// ⇧E: the editor sheet for the selected event, or the one whose detail popover is open.
    func editEvent() {
        guard let event = commandEvent else {
            statusMessage = "Select an event first"
            return
        }
        openEventEditor(event)
    }

    /// `v`: opens the video call of the selected event, or the one whose detail popover is open.
    func joinMeeting() {
        guard let event = commandEvent else {
            statusMessage = "Select an event first"
            return
        }
        guard let url = event.joinURL else {
            statusMessage = "This event has no meeting link"
            return
        }
        open(url: url)
    }

    /// Opens the editor on the store's copy of `event`, closing its detail popover.
    func openEventEditor(_ event: CalendarEvent) {
        guard requireEditable(event) else { return }
        eventDetailID = nil
        eventEditor = EventEditorRequest(event: storedVersion(of: event), isNew: false)
    }

    /// `r y` / `r m` / `r n`: answers the invitation of the selected or open event.
    func respondToEvent(_ status: String) {
        guard let event = commandEvent else {
            statusMessage = "Select an event first"
            return
        }
        guard event.responseStatus != nil else {
            statusMessage = "You are not a guest of this event"
            return
        }
        respond(to: event, status: status)
    }

    /// `x` on an event, or Delete in its detail popover: asks first, since nothing undoes it.
    func confirmDelete(_ event: CalendarEvent) {
        guard requireEditable(event) else { return }
        eventDetailID = nil
        eventToDelete = event
    }

    // MARK: - Writes

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

    /// Upserts the event locally and syncs in the background. Returns false, with a status
    /// message, when its calendar is read-only or the store refused.
    @discardableResult
    func save(event: CalendarEvent, recurrence: EventRecurrence? = nil) -> Bool {
        guard requireEditable(event), let database else { return false }
        do {
            try database.saveEvent(event, recurrence: recurrence)
        } catch {
            statusMessage = "Could not save: \(error.localizedDescription)"
            return false
        }
        scheduleSync()
        return true
    }

    /// status is "accepted", "tentative" or "declined". The own entry in the guest list follows,
    /// so the popover agrees with itself. A declined event leaves the calendar (the store's
    /// queries hide it), so its popover closes and the selection moves on.
    func respond(to event: CalendarEvent, status: String) {
        guard requireEditable(event) else { return }
        let previous = storedVersion(of: event)
        if previous.responseStatus != status {
            var updated = previous
            updated.responseStatus = status
            if var attendees = updated.attendees, let index = attendees.firstIndex(where: \.isSelf) {
                attendees[index].responseStatus = status
                updated.attendees = attendees
            }
            let next = neighbor(of: .event(event.id))
            guard save(event: updated) else { return }
            if status == "declined" {
                didRemove(event, selecting: next)
            }
        }
        switch status {
        case "accepted": showGhost("RSVP: Yes")
        case "tentative": showGhost("RSVP: Maybe")
        default: showGhost("Declined \(Self.quoted(Self.title(of: event)))", for: .seconds(3))
        }
    }

    /// Tombstones the event locally and queues the delete; Google removes it on push.
    func delete(event: CalendarEvent) {
        guard requireEditable(event), let database else { return }
        let next = neighbor(of: .event(event.id))
        do {
            try database.deleteEvent(id: event.id)
        } catch {
            statusMessage = "Could not delete: \(error.localizedDescription)"
            return
        }
        didRemove(event, selecting: next)
        showGhost("Deleted \(Self.quoted(Self.title(of: event)))", for: .seconds(3))
        scheduleSync()
    }

    /// The store's copy of the event (the row a view holds may be a moment old, and a declined
    /// event leaves the calendar while staying in the store).
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

    /// The event's title as the calendar shows it: "(No title)" when it has none.
    static func title(of event: CalendarEvent) -> String {
        if let summary = event.summary, !summary.isEmpty {
            return summary
        }
        return "(No title)"
    }

    /// True when the event's calendar can be written; otherwise says so in the status bar.
    func requireEditable(_ event: CalendarEvent) -> Bool {
        guard canEdit(event) else {
            statusMessage = "This calendar is read-only"
            return false
        }
        return true
    }

    /// After a write took `event` off the calendar: closes its popover and, when it was the
    /// selection, selects `next` (its neighbor from before the write).
    private func didRemove(_ event: CalendarEvent, selecting next: ItemID?) {
        if eventDetailID == event.id {
            eventDetailID = nil
        }
        if selection == .event(event.id) {
            selection = next
        }
    }
}
