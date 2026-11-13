import FloridaKit
import SwiftUI

struct DayBlockingIndicator: View {
    let events: [CalendarEvent]
    let day: Date
    let calendar: Calendar
    var compact = false
    let onSelect: (CalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(events) { event in
                let title = event.summary.flatMap { $0.isEmpty ? nil : $0 } ?? "(No title)"
                Button {
                    onSelect(event)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Protected · \(title)", systemImage: "shield.lefthalf.filled")
                            .font(.caption.weight(.semibold))
                            .lineLimit(compact ? 1 : 2)
                        if !compact {
                            Text(AllDayBlocking.explanation(for: event))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(compact ? 3 : 8)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(FloridaStyle.ink)
                .accessibilityLabel("Protected day, \(day.formatted(.dateTime.month(.wide).day())), \(title)")
                .accessibilityValue(AllDayBlocking.explanation(for: event))
                .accessibilityHint("Shows why this day is protected")
                .accessibilityIdentifier("day-blocking-\(DayOverride.key(for: day, calendar: calendar))-\(event.id)")
            }
        }
    }
}
