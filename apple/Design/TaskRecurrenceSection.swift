import FloridaKit
import SwiftUI

/// Shared native form controls; all recurrence calculation stays in FloridaCore/the server.
struct TaskRecurrenceSection: View {
    @Binding var recurrence: TaskRecurrence?
    let anchorDate: Date?
    let defaultTimeZone: String
    let wasRecurring: Bool
    @State private var startDateEdited = false

    var body: some View {
        Section {
            #if os(macOS)
            MacChoiceField(
                "Repeat", selection: frequency,
                options: [
                    MacChoice("none", "None"),
                    MacChoice("day", "Daily"),
                    MacChoice("week", "Weekly"),
                    MacChoice("month", "Monthly"),
                ],
                identifier: "task-repeat")
            #else
            Picker("Repeat", selection: frequency) {
                Text("None").tag("none")
                Text("Daily").tag("day")
                Text("Weekly").tag("week")
                Text("Monthly").tag("month")
            }
            #endif
            if let rule = recurrence {
                Stepper(value: field(\.interval, default: 1), in: 1...999) {
                    Text("Every \(rule.interval) \(intervalUnit(rule))")
                }
                if rule.frequency == .week {
                    weekdayPicker(rule)
                }
                if rule.frequency == .month {
                    #if os(macOS)
                    MacChoiceField(
                        "Day of month", selection: monthlyDay(rule),
                        options: (1...31).map { MacChoice($0, "\($0)") },
                        identifier: "task-repeat-month-day")
                    #else
                    Picker("Day of month", selection: monthlyDay(rule)) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(day)
                        }
                    }
                    #endif
                }
                #if os(macOS)
                MacDateField("Starts", date: startDate(rule), identifier: "task-repeat-start")
                    .environment(\.timeZone, rule.calendar.timeZone)
                    .environment(\.calendar, rule.calendar)
                #else
                DatePicker("Starts", selection: startDate(rule), displayedComponents: .date)
                    .environment(\.timeZone, rule.calendar.timeZone)
                    .environment(\.calendar, rule.calendar)
                #endif
                Toggle("Ends", isOn: hasEndDate(rule))
                if rule.endDate != nil {
                    #if os(macOS)
                    MacDateField("Through (inclusive)", date: endDate(rule), identifier: "task-repeat-end")
                        .environment(\.timeZone, rule.calendar.timeZone)
                        .environment(\.calendar, rule.calendar)
                    #else
                    DatePicker("Through (inclusive)", selection: endDate(rule), displayedComponents: .date)
                        .environment(\.timeZone, rule.calendar.timeZone)
                        .environment(\.calendar, rule.calendar)
                    #endif
                }
                #if os(macOS)
                MacChoiceField(
                    "Time zone", selection: field(\.timeZone, default: defaultTimeZone),
                    options: timeZones(rule).map {
                        MacChoice($0, $0.replacingOccurrences(of: "_", with: " "))
                    },
                    identifier: "task-repeat-time-zone")
                #else
                Picker("Time zone", selection: field(\.timeZone, default: defaultTimeZone)) {
                    ForEach(timeZones(rule), id: \.self) { zone in
                        Text(zone.replacingOccurrences(of: "_", with: " ")).tag(zone)
                    }
                }
                #endif
                Text(rule.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let next = rule.nextOccurrence(onOrAfter: Date()) {
                    Text("\(wasRecurring ? "Next matching date" : "First occurrence"): \(rule.dateString(for: next))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let message = wasRecurring ? rule.validationMessage : rule.validationMessage(asNewSeriesAt: Date()) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Recurrence")
        } footer: {
            if wasRecurring && recurrence == nil {
                Text("Saving None stops the series and removes future unfinished occurrences. This task stays as a one-off; completed history is kept.")
            } else if recurrence != nil {
                Text("Past dates are not backfilled. Edits apply to this and future unfinished occurrences; completed history is kept. Complete marks only this occurrence done. Delete stops repeats and removes this and future unfinished occurrences.")
            }
        }
        .onChange(of: anchorDate) { updateAnchor(anchorDate) }
    }

    private func updateAnchor(_ date: Date?) {
        guard !wasRecurring, !startDateEdited, let date, let rule = recurrence else { return }
        recurrence?.startDate = rule.dateString(for: date)
    }

    private var frequency: Binding<String> {
        Binding(
            get: { recurrence?.frequency.rawValue ?? "none" },
            set: { value in
                guard let frequency = TaskRecurrence.Frequency(rawValue: value) else {
                    recurrence = nil
                    return
                }
                if var rule = recurrence {
                    rule.frequency = frequency
                    rule.weekdays = nil
                    rule.dayOfMonth = nil
                    recurrence = rule
                } else {
                    startDateEdited = false
                    var rule = TaskRecurrence(frequency: frequency, timeZone: defaultTimeZone, startDate: "")
                    rule.startDate = rule.dateString(for: anchorDate ?? Date())
                    recurrence = rule
                }
            })
    }

    private func field<Value>(_ keyPath: WritableKeyPath<TaskRecurrence, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { recurrence?[keyPath: keyPath] ?? fallback },
            set: { recurrence?[keyPath: keyPath] = $0 })
    }

    private func intervalUnit(_ rule: TaskRecurrence) -> String {
        switch rule.frequency {
        case .day: rule.interval == 1 ? "day" : "days"
        case .week: rule.interval == 1 ? "week" : "weeks"
        case .month: rule.interval == 1 ? "month" : "months"
        }
    }

    private func weekdayPicker(_ rule: TaskRecurrence) -> some View {
        let formatter = DateFormatter()
        let names: [String] = formatter.weekdaySymbols
        let shortNames: [String] = formatter.veryShortWeekdaySymbols
        return HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { day in
                let selected = rule.effectiveWeekdays.contains(day)
                Button {
                    var days = Set(rule.effectiveWeekdays)
                    if selected {
                        // A weekly rule always has at least one day.
                        guard days.count > 1 else { return }
                        days.remove(day)
                    } else {
                        days.insert(day)
                    }
                    recurrence?.weekdays = days.sorted()
                } label: {
                    Text(shortNames.indices.contains(day) ? shortNames[day] : "\(day)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(selected ? Color.accentColor : Color.secondary)
                .accessibilityLabel(names.indices.contains(day) ? names[day] : "Day \(day)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repeat on weekdays")
    }

    private func monthlyDay(_ rule: TaskRecurrence) -> Binding<Int> {
        Binding(get: { recurrence?.effectiveDayOfMonth ?? rule.effectiveDayOfMonth },
                set: { recurrence?.dayOfMonth = $0 })
    }

    private func startDate(_ rule: TaskRecurrence) -> Binding<Date> {
        Binding(
            get: { rule.date(for: recurrence?.startDate ?? rule.startDate) ?? anchorDate ?? Date() },
            set: {
                startDateEdited = true
                recurrence?.startDate = rule.dateString(for: $0)
            })
    }

    private func hasEndDate(_ rule: TaskRecurrence) -> Binding<Bool> {
        Binding(
            get: { recurrence?.endDate != nil },
            set: { recurrence?.endDate = $0 ? (rule.endDate ?? rule.nextOccurrence(onOrAfter: Date()).map(rule.dateString) ?? rule.startDate) : nil })
    }

    private func endDate(_ rule: TaskRecurrence) -> Binding<Date> {
        Binding(
            get: { rule.date(for: recurrence?.endDate ?? rule.startDate) ?? Date() },
            set: { recurrence?.endDate = rule.dateString(for: $0) })
    }

    private func timeZones(_ rule: TaskRecurrence) -> [String] {
        Array(Set(TimeZone.knownTimeZoneIdentifiers + [rule.timeZone, defaultTimeZone])).sorted()
    }
}
