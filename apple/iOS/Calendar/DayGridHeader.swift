import FloridaKit
import SwiftUI

/// Weekday and day number above each column; today is a filled ink circle, as in `WeekStrip`.
struct DayGridHeader: View {
    let days: [Date]
    let today: Date
    let gutterWidth: CGFloat
    let calendar: Calendar

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: gutterWidth, height: 0)
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: today)
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(isToday ? FloridaStyle.ink : Color.secondary)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.body.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? FloridaStyle.paper : FloridaStyle.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: 30, height: 30)
                        .background {
                            if isToday {
                                Circle().fill(FloridaStyle.ink)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .accessibilityValue(isToday ? "Today" : "")
            }
        }
    }
}

/// All-day events as bars spanning their day columns, one row per `AllDayLayout` row. The
/// parent leaves it out when the visible days have none.
struct DayGridAllDayStrip: View {
    let layout: DayGridLayout
    let geometry: DayGridGeometry
    let now: Date
    let onSelect: (CalendarEvent) -> Void

    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 22

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: geometry.gutterWidth - 8, height: rowHeight, alignment: .trailing)
            ForEach(layout.allDayBlocks) { block in
                let frame = frame(for: block)
                AllDayBar(block: block, isPast: block.localEnd <= now)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .onTapGesture {
                        onSelect(block.event)
                    }
            }
        }
        .frame(width: geometry.width, height: CGFloat(layout.allDayRowCount) * rowHeight + 2, alignment: .topLeading)
    }

    /// Where the bar sits in the strip; plain `let`s so the type checker does not have to fold
    /// the chain inside the `ForEach`.
    private func frame(for block: DayGridLayout.AllDayBlock) -> CGRect {
        let spannedDays = CGFloat(block.endDayIndex - block.startDayIndex + 1)
        let width: CGFloat = max(spannedDays * geometry.columnWidth - 4, 4)
        let x: CGFloat = geometry.x(forDay: block.startDayIndex) + 2
        let y: CGFloat = CGFloat(block.row) * rowHeight + 2
        return CGRect(x: x, y: y, width: width, height: rowHeight - 4)
    }
}

private struct AllDayBar: View {
    let block: DayGridLayout.AllDayBlock
    /// The event's last local day has ended (its stored UTC start would dim it a day early).
    let isPast: Bool

    var body: some View {
        let opacity: Double = isPast ? 0.6 : 1
        let shape = RoundedRectangle(cornerRadius: 4)
        Text(block.title)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(FloridaStyle.ink.opacity(opacity))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(block.tint.opacity(0.12 * opacity), in: shape)
            .overlay(shape.strokeBorder(block.tint.opacity(0.4 * opacity), lineWidth: 1))
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(block.title)
            .accessibilityValue("All day")
            .accessibilityAddTraits(.isButton)
    }
}
