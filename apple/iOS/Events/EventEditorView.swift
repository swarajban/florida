import FloridaKit
import SwiftUI

/// Sheet for one Google event. Editing works on a copy written back with Save; Cancel discards.
/// In create mode (`isNew`) the same form adds the event on a calendar of the user's choice; an
/// existing event stays on its calendar, since moving between calendars is not supported.
///
/// The draft keeps the server's shape throughout: an all-day event's `startAt`/`endAt` are the
/// stored UTC-midnight instants (the end being the day after the last day), converted for the
/// pickers through `AllDayDate` in both directions.
struct EventEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CalendarEvent
    @State private var recurrence: EventRecurrence?
    /// The clock and length of the timed event from before All-day was switched on, so switching
    /// it off again brings them back on whatever day is chosen by then.
    @State private var timedShape: (hour: Int, minute: Int, duration: TimeInterval)?
    @FocusState private var titleFocused: Bool
    private let isNew: Bool

    init(event: CalendarEvent, isNew: Bool) {
        self.isNew = isNew
        var event = event
        // Rows without times never reach the agenda, but the shape allows them; give the pickers something.
        if event.startAt == nil || event.endAt == nil {
            let start = event.startAt ?? event.endAt ?? Date()
            event.startAt = start
            event.endAt = event.endAt ?? start.addingTimeInterval(30 * 60)
        }
        _draft = State(initialValue: event)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: title)
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit { titleFocused = false }
                }

                Section {
                    Picker("Calendar", selection: $draft.calendarId) {
                        ForEach(calendarChoices) { info in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(info.color.flatMap(Color.init(hex:)) ?? .secondary)
                                    .frame(width: 10, height: 10)
                                Text(info.summary)
                            }
                            .tag(info.id)
                        }
                    }
                    .disabled(!isNew)
                } footer: {
                    if isNew, model.writableCalendars.isEmpty {
                        Text("No calendar you can add events to. Connect a Google account in Settings.")
                    }
                }

                Section {
                    Toggle("All-day", isOn: allDay)
                    DatePicker("Starts", selection: start, displayedComponents: dateComponents)
                        .datePickerStyle(.compact)
                        .accessibilityIdentifier("event-start")
                    DatePicker("Ends", selection: end, displayedComponents: dateComponents)
                        .datePickerStyle(.compact)
                        .accessibilityIdentifier("event-end")
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
                    TextField("Notes", text: notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(isNew ? "New Event" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                titleFocused = isNew && (draft.summary ?? "").isEmpty
            }
        }
        .presentationDetents([.large])
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

    private var dateComponents: DatePickerComponents {
        draft.allDay ? [.date] : [.date, .hourAndMinute]
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
        return writable + (model.calendarInfo(id: draft.calendarId).map { [$0] } ?? [])
    }

    private var canSave: Bool {
        endsAfterStart && (!isNew || model.writableCalendars.contains { $0.id == draft.calendarId })
    }

    /// Writes the edited fields over the store's row, so a sync since the sheet opened (a guest's
    /// answer, say) is kept, then closes. A failure shows in the toast.
    private func save() {
        var event = model.storedVersion(of: draft)
        event.calendarId = draft.calendarId
        event.summary = Self.cleaned(draft.summary)
        event.location = Self.cleaned(draft.location)
        event.description = Self.cleaned(draft.description)
        event.allDay = draft.allDay
        event.startAt = draft.startAt
        event.endAt = draft.endAt
        guard model.save(event: event, recurrence: isNew ? recurrence : nil) else { return }
        dismiss()
    }

    /// Trimmed; nil when nothing is left.
    private static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
