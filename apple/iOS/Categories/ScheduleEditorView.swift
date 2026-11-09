import FloridaKit
import SwiftUI

/// Sheet to add or edit a schedule: name, IANA time zone, and the hours per weekday (any number
/// of windows a day; "Copy to…" repeats one day's hours on others). Validates as the server does
/// and shows problems in place before saving.
struct ScheduleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var schedule: Schedule
    @State private var hours: WeeklyHours
    @State private var saveError: String?
    let isNew: Bool

    init(schedule: Schedule, isNew: Bool) {
        _schedule = State(initialValue: schedule)
        _hours = State(initialValue: WeeklyHours(windows: schedule.windows))
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $schedule.name)
                    NavigationLink {
                        TimeZonePicker(selection: $schedule.timeZone)
                    } label: {
                        LabeledContent("Time zone", value: schedule.timeZone)
                    }
                } footer: {
                    if let message = saveError ?? hours.problem {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Text("Hours are wall-clock times in this time zone.")
                    }
                }

                ForEach(Self.weekOrder(model.calendar), id: \.self) { day in
                    Section {
                        ForEach($hours.days[day]) { $range in
                            HStack {
                                MinutePicker(label: "From", minutes: $range.start)
                                Text("–")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                MinutePicker(label: "To", minutes: $range.end)
                            }
                        }
                        .onDelete { offsets in
                            hours.days[day].remove(atOffsets: offsets)
                        }
                        Button {
                            hours.addRange(day: day)
                        } label: {
                            Label("Add hours", systemImage: "plus")
                        }
                    } header: {
                        HStack {
                            Text(model.calendar.weekdaySymbols[day])
                            Spacer()
                            if !hours.days[day].isEmpty {
                                copyMenu(from: day)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Schedule" : "Edit Schedule")
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
                    .disabled(schedule.name.trimmingCharacters(in: .whitespaces).isEmpty || hours.problem != nil)
                }
            }
            .onChange(of: hours) { _, _ in
                saveError = nil
            }
        }
    }

    private func copyMenu(from day: Int) -> some View {
        Menu {
            Button("Weekdays") {
                hours.copy(day: day, to: [1, 2, 3, 4, 5])
            }
            Button("Every day") {
                hours.copy(day: day, to: Array(0..<7))
            }
        } label: {
            Text("Copy to…")
                .font(.caption)
                .textCase(nil)
        }
        .accessibilityLabel("Copy \(model.calendar.weekdaySymbols[day])'s hours")
    }

    /// Weekday indexes (0 = Sunday) starting on the user's first day of the week.
    static func weekOrder(_ calendar: Calendar) -> [Int] {
        let first = calendar.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }
    }

    private func save() {
        var updated = schedule
        updated.windows = hours.windows
        do {
            try model.saveSchedule(updated)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// A compact time picker over minutes after midnight. Uses a UTC calendar so a DST change on the
/// reference day can never shift the value.
private struct MinutePicker: View {
    let label: String
    @Binding var minutes: Int

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = EventTiming.utc
        return calendar
    }()

    var body: some View {
        DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .environment(\.timeZone, EventTiming.utc)
            .environment(\.calendar, Self.utc)
            .accessibilityLabel(label)
    }

    private var date: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: TimeInterval(minutes * 60)) },
            set: { value in
                let parts = Self.utc.dateComponents([.hour, .minute], from: value)
                minutes = min((parts.hour ?? 0) * 60 + (parts.minute ?? 0), WeeklyHours.lastMinute)
            })
    }
}
