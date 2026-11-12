import AppKit
import FloridaKit
import Foundation

// Google events, local-first like tasks: an RSVP, an edit, a new event or a delete lands in the
// store at once (the live query redraws the calendar) and a background sync pushes it. Writes are
// refused here, with a status message, for calendars the user cannot write to; nothing waits on
// Google. Of these only a move by drag can be undone (`z`); a delete asks first instead.

/// What the event editor sheet is open on: a stored event, or the draft of a new one.
struct EventEditorRequest: Identifiable, Equatable {
    var id: String { event.id }
    let event: CalendarEvent
    let isNew: Bool
    var showsComposer = false
}

/// A dragged event dropped on a new time, waiting for an answer: it repeats (this one or all of
/// them?), or it has guests, who get an email.
struct EventMoveRequest: Identifiable, Equatable {
    var id: String { event.id }
    let event: CalendarEvent
    let start: Date
    /// The event repeats and was dropped on its own day, so the series can take the new time of
    /// day. A drop on another day can only move this one: every instance keeps its day.
    let canMoveSeries: Bool

    var repeats: Bool { event.recurringEventId != nil }
    var hasGuests: Bool { event.attendees?.contains(where: { !$0.isSelf }) == true }
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
        calendars.filter(Self.isWritable).sorted { CalendarInfo.isPreferredForNewEvents($0, $1, accounts: accounts) }
    }

    /// The event the event keys act on: the one whose detail popover is open, else the selected one.
    var commandEvent: CalendarEvent? {
        if let id = eventDetailID, let event = events.first(where: { $0.id == id }) {
            return event
        }
        return selectedEvent
    }

    // MARK: - Commands

    /// ⇧C / `>New event`: the composer on a blank 30-minute event. Without `start` it begins at the
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
        eventEditor = EventEditorRequest(event: newEventTemplate(start: start ?? fallback), isNew: true, showsComposer: true)
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

    func openEventResources() {
        guard let event = commandEvent else {
            statusMessage = "Select an event first"
            return
        }
        guard !event.resources.isEmpty else {
            statusMessage = "This event has no resources"
            return
        }
        eventDetailID = nil
        openPalette(mode: .eventResources(eventId: event.id))
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func openEventResource(_ resource: EventResource) {
        eventDetailID = nil
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "demoData"), UserDefaults.standard.bool(forKey: "uiRecordResourceOpens") {
            statusMessage = "Opened resource: \(resource.url.absoluteString)"
            return
        }
        #endif
        open(url: resource.url)
    }

    func handleEventResourceKey(_ chord: KeyChord) -> Bool {
        guard !isSheetOpen, !isPaletteOpen, !isHelpOpen,
              let id = eventDetailID, let event = events.first(where: { $0.id == id }),
              (NSApplication.shared.keyWindow?.firstResponder as? NSTextView)?.isEditable != true
        else { return false }
        guard chord.modifiers.isEmpty, chord.key.count == 1, "1234567890".contains(chord.key) else {
            eventResourceKeys = nil
            return false
        }
        let resources = event.resources
        guard !resources.isEmpty else { return false }
        matcher.reset()
        pendingKeys = ""
        var labels = eventResourceKeys ?? JumpLabels(items: resources.map(\.id), alphabet: Array("1234567890"))
        switch labels.type(chord.key) {
        case .selected(let id):
            eventResourceKeys = nil
            if let resource = resources.first(where: { $0.id == id }) {
                openEventResource(resource)
            }
        case .pending:
            eventResourceKeys = labels
        case .unmatched:
            eventResourceKeys = nil
        }
        return true
    }

    func cycleEventDayBlocking() {
        guard let event = commandEvent else {
            statusMessage = "Select an all-day event first"
            return
        }
        let current = storedVersion(of: event)
        guard current.allDay else {
            statusMessage = "Blocks my day is only for all-day events"
            return
        }
        let next: Bool?
        switch current.blocksDay {
        case nil: next = true
        case true?: next = false
        case false?: next = nil
        }
        setBlocksDay(current, blocksDay: next)
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

    func setBlocksDay(_ event: CalendarEvent, blocksDay: Bool?) {
        let current = storedVersion(of: event)
        guard current.allDay, let database else { return }
        do {
            try database.setEventBlocksDay(id: current.id, blocksDay: blocksDay)
        } catch {
            statusMessage = "Could not save: \(error.localizedDescription)"
            return
        }
        scheduleSync()
    }

    // MARK: - Drag

    /// The start of a drag on `block` in the time grid. Nil, with a word in the status bar, for
    /// what a drag cannot move: tasks (the scheduler places them), the gym, an event on a
    /// read-only calendar, and the part of an event that crosses midnight.
    func beginDrag(on block: GridLayout.Block?) -> GridDrag? {
        guard let block else { return nil }
        guard case .event(let id) = block.item, let event = events.first(where: { $0.id == id }) else {
            if block.isTask {
                statusMessage = "The scheduler places tasks · p pins one to its slot"
            }
            return nil
        }
        guard requireEditable(event) else { return nil }
        // Such an event has a block in two day columns, each showing only its part of it.
        guard let start = event.startAt, let end = event.endAt,
              end <= start || calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1))
        else {
            statusMessage = "This event crosses midnight · ⇧E edits its times"
            return nil
        }
        eventDetailID = nil
        select(block.item, in: .calendar)
        return GridDrag(block: block, event: event)
    }

    /// The end of a drag. Back in its own slot the event is left alone. A repeating event asks
    /// whether this one moves or all of them. With guests it asks too: a slip of the hand should
    /// not send everyone a new time.
    func drop(_ drag: GridDrag) {
        guard drag.hasMoved else {
            gridDrag = nil
            return
        }
        let stored = storedVersion(of: drag.event)
        guard stored.startAt == drag.event.startAt, stored.endAt == drag.event.endAt, stored.deletedAt == nil else {
            gridDrag = nil
            statusMessage = "That event changed while it was dragged"
            return
        }
        var dropped = drag
        dropped.isDropped = true
        gridDrag = dropped
        let sameDay = stored.startAt.map { calendar.isDate($0, inSameDayAs: drag.start) } ?? false
        let request = EventMoveRequest(
            event: stored, start: drag.start, canMoveSeries: stored.recurringEventId != nil && sameDay)
        if request.repeats || request.hasGuests {
            eventMove = request
        } else {
            move(event: stored, toStart: drag.start)
        }
    }

    /// The move dialog's title.
    func moveQuestion(_ request: EventMoveRequest) -> String {
        request.canMoveSeries ? "Move this event or all of them?" : "Move this event?"
    }

    /// The move dialog's text: where the event goes, what each answer moves, and who hears of it.
    func moveMessage(_ request: EventMoveRequest) -> String {
        let title = Self.quoted(Self.title(of: request.event))
        let when = DateText.dayAndTime(request.start, calendar: calendar)
        var text: String
        if request.canMoveSeries {
            text = "\(title) repeats. This Event moves only this one to \(when). "
                + "All Events moves every one to \(DateText.time(request.start)) on its own day."
        } else if request.repeats {
            text = "\(title) repeats. Only this one moves to \(when); drop it on its own day to move them all."
        } else {
            text = "\(title) moves to \(when)."
        }
        if request.hasGuests {
            text += " Google emails its guests the new time."
        }
        return text
    }

    /// The answer was no, or the question was dismissed: the block goes back. Does nothing once
    /// the answer was yes, which clears the request first.
    func cancelEventMove() {
        guard eventMove != nil else { return }
        eventMove = nil
        gridDrag = nil
    }

    /// Moves a timed event to `start`, keeping its length; `z` puts it back.
    func move(event: CalendarEvent, toStart start: Date) {
        guard let oldStart = event.startAt, let oldEnd = event.endAt, oldEnd >= oldStart else {
            gridDrag = nil
            return
        }
        var moved = event
        let end = start.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
        moved.startAt = start
        moved.endAt = end
        guard save(event: moved) else {
            gridDrag = nil
            return
        }
        pushUndo(UndoEntry(
            label: "Moved \(Self.quoted(Self.title(of: event)))",
            restores: [.moveEvent(
                eventId: event.id, from: DateInterval(start: oldStart, end: oldEnd), to: DateInterval(start: start, end: end))],
            at: Date()))
        showGhost("Moved to \(DateText.dayAndTime(start, calendar: calendar)) · z to undo", for: .seconds(3))
    }

    /// Moves every instance of a repeating event to the time of day `event` was dropped on, each
    /// on its own day; `z` moves them back. The store shifts the instances it holds at once, and
    /// the server moves the series on Google from the one queued write.
    func moveSeries(of event: CalendarEvent, toStart start: Date) {
        guard requireEditable(event), let database, let oldStart = event.startAt, let oldEnd = event.endAt,
              oldEnd >= oldStart
        else {
            gridDrag = nil
            return
        }
        let end = start.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
        do {
            try database.moveEventSeries(instanceId: event.id, start: start, end: end)
        } catch {
            gridDrag = nil
            statusMessage = "Could not save: \(error.localizedDescription)"
            return
        }
        scheduleSync()
        pushUndo(UndoEntry(
            label: "Moved every \(Self.quoted(Self.title(of: event)))",
            restores: [.moveEventSeries(
                eventId: event.id, from: DateInterval(start: oldStart, end: oldEnd), to: DateInterval(start: start, end: end))],
            at: Date()))
        showGhost("Moved all to \(DateText.time(start)) · z to undo", for: .seconds(3))
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
