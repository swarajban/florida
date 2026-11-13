import FloridaKit
import SwiftUI

/// Edits a Google event, or fills in a new one from capture's Details. Editing works on a copy
/// written back with Save; Cancel discards. A new event goes on a calendar of the user's choice;
/// an existing one stays on its calendar, since moving between calendars is not supported. Save
/// writes locally and closes; nothing waits on Google.
///
/// The draft keeps the server's shape throughout: an all-day event's `startAt`/`endAt` are the
/// stored UTC-midnight instants (the end being the day after the last day), converted for the
/// pickers through `AllDayDate` in both directions.
struct EventEditorSheet: View {
    @Environment(AppModel.self) private var model
    @State private var draft: CalendarEvent
    private let original: CalendarEvent
    @State private var saveError: String?
    @State private var recurrence: EventRecurrence?
    /// The clock and length of the timed event from before All-day was switched on, so switching
    /// it off again brings them back on whatever day is chosen by then.
    @State private var timedShape: (hour: Int, minute: Int, duration: TimeInterval)?
    @FocusState private var isTitleFocused: Bool
    /// Not in the store yet: titled "New event", offers the calendar, and saves as "Added".
    let isNew: Bool

    init(event: CalendarEvent, isNew: Bool, recurrence: EventRecurrence? = nil) {
        original = event
        self.isNew = isNew
        _recurrence = State(initialValue: recurrence)
        var event = event
        // Rows without times never reach the calendar, but the shape allows them; give the pickers something.
        if event.startAt == nil || event.endAt == nil {
            let start = event.startAt ?? event.endAt ?? Date()
            event.startAt = start
            event.endAt = event.endAt ?? start.addingTimeInterval(30 * 60)
        }
        _draft = State(initialValue: event)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("event-save-error")
                }
                Section(isNew ? "New event" : "Event") {
                    TextField("Title", text: title)
                        .focused($isTitleFocused)
                        .accessibilityIdentifier("event-editor-title")
                    MacChoiceField(
                        "Calendar", selection: $draft.calendarId,
                        options: calendarChoices.map { MacChoice($0.id, $0.summary) },
                        identifier: "event-calendar")
                    .disabled(!isNew)
                    if let account = model.accounts.first(where: { $0.id == model.calendarsById[draft.calendarId]?.accountId }) {
                        Text(account.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("event-editor-account")
                    }
                }
                Section {
                    Toggle("All-day", isOn: allDay)
                        .accessibilityIdentifier("event-editor-all-day")
                    QuarterHourDatePicker(title: "Starts", date: start, showsTime: !draft.allDay)
                    QuarterHourDatePicker(title: "Ends", date: end, showsTime: !draft.allDay)
                } footer: {
                    if !endsAfterStart {
                        Label("The end must be after the start.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if isNew {
                    EventRecurrenceSection(recurrence: $recurrence, timeZone: calendar.timeZone.identifier)
                } else if draft.recurringEventId != nil {
                    Section {
                        Text("Part of a repeating event. Changes here apply to this occurrence only. Edit the series in Google Calendar.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Location", text: location)
                        .accessibilityIdentifier("event-editor-location")
                    TextField("Description", text: notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") {
                    model.eventEditor = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Add Event" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .onAppear {
            DispatchQueue.main.async { isTitleFocused = true }
        }
    }

    // MARK: - Bindings over optional fields

    private var title: Binding<String> {
        Binding(
            get: { draft.summary ?? "" },
            set: { draft.summary = $0.isEmpty ? nil : $0 })
    }

    private var location: Binding<String> {
        Binding(
            get: { draft.location ?? "" },
            set: { draft.location = $0.isEmpty ? nil : $0 })
    }

    private var notes: Binding<String> {
        Binding(
            get: { draft.description ?? "" },
            set: { draft.description = $0.isEmpty ? nil : $0 })
    }

    private var allDay: Binding<Bool> {
        Binding(
            get: { draft.allDay },
            set: { setAllDay($0) })
    }

    private var start: Binding<Date> {
        Binding(
            get: { shownStart },
            set: { moveStart(to: $0) })
    }

    private var end: Binding<Date> {
        Binding(
            get: { shownEnd },
            set: { setEnd($0) })
    }

    // MARK: - Dates

    private var calendar: Calendar {
        model.calendar
    }

    /// Both filled in `init`, so the fallbacks are never used.
    private var storedStart: Date {
        draft.startAt ?? draft.updatedAt
    }

    private var storedEnd: Date {
        draft.endAt ?? storedStart
    }

    /// What the Starts picker shows: the instant, or an all-day event's first day as a local midnight.
    private var shownStart: Date {
        draft.allDay ? localDay(of: storedStart) : storedStart
    }

    /// What the Ends picker shows: the instant, or an all-day event's last day as a local midnight
    /// (the stored end is the day after it).
    private var shownEnd: Date {
        guard draft.allDay else { return storedEnd }
        let dayAfter = localDay(of: storedEnd)
        return calendar.date(byAdding: .day, value: -1, to: dayAfter) ?? dayAfter
    }

    /// Valid for a timed event and, since the stored end is the day after the last day, for an
    /// all-day event ending on or after the day it starts.
    private var endsAfterStart: Bool {
        storedEnd > storedStart
    }

    /// Moves the start and carries the end along so the length stays: by the same interval for a
    /// timed event, by the same number of days for an all-day one.
    private func moveStart(to newStart: Date) {
        if draft.allDay {
            let newDay = calendar.startOfDay(for: newStart)
            let days = calendar.dateComponents([.day], from: shownStart, to: newDay).day ?? 0
            let lastDay = calendar.date(byAdding: .day, value: days, to: shownEnd) ?? shownEnd
            draft.startAt = AllDayDate.storedInstant(forLocalDay: newDay, calendar: calendar)
            draft.endAt = storedEnd(afterLastDay: lastDay)
        } else {
            draft.endAt = storedEnd.addingTimeInterval(newStart.timeIntervalSince(storedStart))
            draft.startAt = newStart
        }
    }

    private func setEnd(_ newEnd: Date) {
        draft.endAt = draft.allDay ? storedEnd(afterLastDay: calendar.startOfDay(for: newEnd)) : newEnd
    }

    /// On: the local days the timed event touched (a 9 PM – midnight event is one day). Off: the
    /// clock and length from before it was switched on, else 9:00 for 30 minutes, on the first day.
    private func setAllDay(_ on: Bool) {
        guard on != draft.allDay else { return }
        if on {
            let clock = calendar.dateComponents([.hour, .minute], from: storedStart)
            timedShape = (clock.hour ?? 9, clock.minute ?? 0, storedEnd.timeIntervalSince(storedStart))
            let firstDay = calendar.startOfDay(for: storedStart)
            let lastDay = calendar.startOfDay(for: max(storedStart, storedEnd.addingTimeInterval(-1)))
            draft.startAt = AllDayDate.storedInstant(forLocalDay: firstDay, calendar: calendar)
            draft.endAt = storedEnd(afterLastDay: lastDay)
        } else {
            let shape = timedShape ?? (hour: 9, minute: 0, duration: 30 * 60)
            let firstDay = shownStart
            let start = calendar.date(bySettingHour: shape.hour, minute: shape.minute, second: 0, of: firstDay) ?? firstDay
            draft.startAt = start
            draft.endAt = start.addingTimeInterval(max(shape.duration, 0))
        }
        draft.allDay = on
    }

    /// The stored end of an all-day event whose last day is `lastDay`: the stored instant of the day after.
    private func storedEnd(afterLastDay lastDay: Date) -> Date {
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86_400)
        return AllDayDate.storedInstant(forLocalDay: dayAfter, calendar: calendar)
    }

    /// The local midnight of the day a stored all-day instant stands for.
    private func localDay(of stored: Date) -> Date {
        AllDayDate.localDays(start: stored, end: stored, calendar: calendar).lowerBound
    }

    // MARK: - Calendar and saving

    /// The calendars offered: those the user can write to, plus (when editing) the event's own if
    /// it is not among them, so the picker always holds its selection.
    private var calendarChoices: [CalendarInfo] {
        let writable = model.writableCalendars
        if writable.contains(where: { $0.id == draft.calendarId }) {
            return writable
        }
        return writable + (model.calendarsById[draft.calendarId].map { [$0] } ?? [])
    }

    private var canSave: Bool {
        endsAfterStart && (!isNew || model.writableCalendars.contains { $0.id == draft.calendarId })
    }

    /// Writes the edited fields over the store's row, so a sync since the sheet opened (a guest's
    /// answer, say) is kept, then closes. A failure shows in the status bar and keeps the sheet.
    /// A new event is selected on its day, so it is in view once the calendar redraws.
    private func save() {
        guard canSave else { return }
        var event = draft
        if isNew || draft.summary != original.summary {
            event.summary = Self.cleaned(draft.summary)
        }
        if isNew || draft.location != original.location {
            event.location = Self.cleaned(draft.location)
        }
        if isNew || draft.description != original.description {
            event.description = Self.cleaned(draft.description)
        }
        event.allDay = draft.allDay
        event.startAt = draft.startAt
        event.endAt = draft.endAt
        guard model.save(event: event, original: isNew ? nil : original, recurrence: isNew ? recurrence : nil) else {
            saveError = model.statusMessage ?? "The event could not be saved."
            return
        }
        model.eventEditor = nil
        if isNew {
            model.selectDay(shownStart)
            model.select(.event(event.id), in: .calendar)
            model.showGhost("Added to \(model.calendarsById[event.calendarId]?.summary ?? "calendar")")
        }
    }

    /// Trimmed; nil when nothing is left.
    private static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
