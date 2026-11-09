import FloridaKit
import SwiftUI

/// Edits one schedule as a draft: name, time zone, and each weekday's windows. Save writes it
/// locally (and syncs); Revert throws the draft away.
struct ScheduleEditorView: View {
    @Environment(AppModel.self) private var model
    let schedule: Schedule
    @State private var draft: ScheduleDraft

    init(schedule: Schedule) {
        self.schedule = schedule
        _draft = State(initialValue: ScheduleDraft(schedule))
    }

    private static let timeZones: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name)
                Picker("Time zone", selection: $draft.timeZone) {
                    ForEach(zones, id: \.self) { zone in
                        Text(zone.replacingOccurrences(of: "_", with: " ")).tag(zone)
                    }
                }
                Section("Hours") {
                    ForEach(Self.weekdayOrder, id: \.self) { day in
                        WeekdayWindowsRow(day: day, windows: $draft.days[day]) {
                            draft.addWindow(on: day)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let problem = draft.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Revert") {
                    draft = ScheduleDraft(schedule)
                }
                .disabled(!draft.differs(from: schedule))
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.problem != nil || !draft.differs(from: schedule))
            }
            .padding(10)
        }
    }

    /// The known zones, plus the schedule's own if the system does not list it.
    private var zones: [String] {
        Self.timeZones.contains(draft.timeZone) ? Self.timeZones : [draft.timeZone] + Self.timeZones
    }

    /// Weekdays starting at the user's first day of the week.
    private static var weekdayOrder: [Int] {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }
    }

    private func save() {
        var updated = schedule
        updated.name = draft.name.trimmingCharacters(in: .whitespaces)
        updated.timeZone = draft.timeZone
        updated.windows = draft.windows()
        if model.save(updated) {
            model.showGhost("Saved \(updated.name)")
        }
    }
}

/// One weekday: its windows as start–end time fields with remove buttons, and "+".
struct WeekdayWindowsRow: View {
    let day: Int
    @Binding var windows: [ScheduleDraft.Window]
    let onAdd: () -> Void

    var body: some View {
        LabeledContent(Calendar.current.weekdaySymbols[day]) {
            VStack(alignment: .trailing, spacing: 4) {
                if windows.isEmpty {
                    Text("Off")
                        .foregroundStyle(.secondary)
                }
                ForEach($windows) { $window in
                    HStack(spacing: 4) {
                        ClockField(minutes: $window.start)
                        Text("–")
                        ClockField(minutes: $window.end)
                        Button {
                            windows.removeAll { $0.id == window.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button(action: onAdd) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add hours")
            }
        }
    }
}

/// A time-of-day field bound to minutes after midnight.
struct ClockField: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker("Time", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
    }

    /// Minutes on a fixed day in the local calendar, which the picker displays and edits.
    private var date: Binding<Date> {
        let calendar = Calendar.current
        let reference = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15)) ?? Date()
        return Binding(
            get: {
                let clamped = min(max(minutes, 0), ClockTime.lastMinute)
                return calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: reference) ?? reference
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                minutes = min((parts.hour ?? 0) * 60 + (parts.minute ?? 0), ClockTime.lastMinute)
            })
    }
}
