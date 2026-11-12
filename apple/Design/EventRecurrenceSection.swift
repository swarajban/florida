import FloridaKit
import SwiftUI

/// Google expands the series; both editors only collect the creation rule.
struct EventRecurrenceSection: View {
    @Binding var recurrence: EventRecurrence?
    let timeZone: String

    var body: some View {
        Section {
            #if os(macOS)
            MacChoiceField(
                "Repeat", selection: frequency,
                options: [
                    MacChoice("none", "Does not repeat"),
                    MacChoice("daily", "Daily"),
                    MacChoice("weekly", "Weekly"),
                    MacChoice("monthly", "Monthly"),
                    MacChoice("yearly", "Yearly"),
                ],
                identifier: "event-repeat")
            #else
            Picker("Repeat", selection: frequency) {
                Text("Does not repeat").tag("none")
                Text("Daily").tag("daily")
                Text("Weekly").tag("weekly")
                Text("Monthly").tag("monthly")
                Text("Yearly").tag("yearly")
            }
            .accessibilityIdentifier("event-repeat")
            .menuActionDismissBehavior(.enabled)
            #endif
            if let rule = recurrence {
                Stepper(value: Binding(
                    get: { recurrence?.interval ?? 1 },
                    set: { recurrence?.interval = $0 }), in: 1...99) {
                    Text("Every \(rule.interval) \(unit(rule))")
                }
                .accessibilityIdentifier("event-repeat-interval")
                Toggle("Limit occurrences", isOn: Binding(
                    get: { recurrence?.count != nil },
                    set: { recurrence?.count = $0 ? 10 : nil }))
                .accessibilityIdentifier("event-repeat-limit")
                if rule.count != nil {
                    Stepper(value: Binding(
                        get: { recurrence?.count ?? 10 },
                        set: { recurrence?.count = $0 }), in: 1...999) {
                        Text("Ends after \(rule.count ?? 10) occurrences")
                    }
                }
            }
        } footer: {
            if let rule = recurrence {
                Text("Repeats from Starts in \(rule.timeZone.replacingOccurrences(of: "_", with: " ")). \(rule.count == nil ? "No end date. " : "")Google Calendar manages the series; later edits here change one occurrence.")
                if rule.frequency == .monthly || rule.frequency == .yearly {
                    Text("Dates that do not exist in a month or year are skipped.")
                }
            }
        }
    }

    private var frequency: Binding<String> {
        Binding(
            get: { recurrence?.frequency.rawValue ?? "none" },
            set: { value in
                guard let frequency = EventRecurrence.Frequency(rawValue: value) else {
                    recurrence = nil
                    return
                }
                if recurrence == nil {
                    recurrence = EventRecurrence(frequency: frequency, timeZone: timeZone)
                } else {
                    recurrence?.frequency = frequency
                }
            })
    }

    private func unit(_ rule: EventRecurrence) -> String {
        let noun: String = switch rule.frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
        return noun + (rule.interval == 1 ? "" : "s")
    }
}
