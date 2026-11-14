import FloridaKit
import SwiftUI

struct AgendaDayStatus: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let events: [CalendarEvent]
    var compact = false
    let onSelect: (CalendarEvent) -> Void

    var body: some View {
        let kind = model.dayKind(of: day)
        let isChanged = model.dayOverride(on: day) != nil
        let routine = DayKind.of(day: day, calendar: model.calendar, blocks: model.routineBlocks, overrides: [])
        let protected = (kind != .off && !events.isEmpty) || (kind == .off && isChanged && routine != .off)
        let title = protected ? "Protected" : kind.label
        Menu {
            if !events.isEmpty {
                Section("Protected day") {
                    ForEach(events) { event in
                        Button { onSelect(event) } label: {
                            Label(event.summary ?? "(No title)", systemImage: "shield.lefthalf.filled")
                            Text(AllDayBlocking.explanation(for: event))
                        }
                        .accessibilityLabel("Protected day, \(day.formatted(.dateTime.month(.wide).day())), \(event.summary ?? "(No title)")")
                        .accessibilityValue(AllDayBlocking.explanation(for: event))
                        .accessibilityIdentifier("day-blocking-\(DayOverride.key(for: day, calendar: model.calendar))-\(event.id)")
                    }
                }
            }
            if kind == .off && isChanged {
                Text("Manual override: Day off")
            }
            Picker("Day", selection: Binding(get: { kind }, set: { model.setDay(day, kind: $0) })) {
                ForEach(DayKind.allCases, id: \.self) { option in
                    Label(option.label, systemImage: option.symbolName).tag(option)
                }
            }
            if isChanged {
                Button { model.clearDayOverride(on: day) } label: {
                    Label("Back to the routine", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: protected ? "shield.lefthalf.filled" : kind.symbolName)
                if !compact {
                    Text(title)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
            .font(.subheadline)
            .fixedSize()
            .frame(minWidth: compact ? 44 : nil, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(protected || isChanged ? FloridaStyle.ink : Color.secondary)
        .accessibilityLabel(title)
        .accessibilityValue(([isChanged ? "Changed for this day" : "From the routine"]
            + events.map { "\($0.summary ?? "(No title)"). \(AllDayBlocking.explanation(for: $0))" }).joined(separator: ". "))
        .accessibilityHint("Changes the day kind and shows protection reasons")
    }
}
