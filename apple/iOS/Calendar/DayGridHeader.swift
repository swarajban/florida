import FloridaKit
import SwiftUI

/// Weekday and day number above each column; today is a filled ink circle, as in `WeekStrip`.
/// Only the three-day grid shows it: a single day is already named by the heading and the week
/// strip above the grid.
struct DayGridHeader: View {
    @Environment(AppModel.self) private var model
    let days: [Date]
    let today: Date
    let gutterWidth: CGFloat
    let columnWidth: CGFloat
    let pinnedGutterX: CGFloat
    let calendar: Calendar
    let blockingByDay: [Date: [CalendarEvent]]
    let onSelect: (CalendarEvent) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: gutterWidth, height: 0)
            ZStack(alignment: .leading) {
                ForEach(days, id: \.self) { day in
                    let isToday = calendar.isDate(day, inSameDayAs: today)
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2)
                            .foregroundStyle(isToday ? FloridaStyle.ink : Color.secondary)
                        HStack(spacing: 0) {
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
                            if !(blockingByDay[day] ?? []).isEmpty {
                                AgendaDayStatus(day: day, events: blockingByDay[day] ?? [], compact: true, onSelect: onSelect)
                                    .accessibilityIdentifier("agenda-day-kind-\(DayOverride.key(for: day, calendar: calendar))")
                            }
                        }
                    }
                    .frame(width: columnWidth)
                    .padding(.vertical, 4)
                    .offset(x: CGFloat(days.firstIndex(of: day) ?? 0) * columnWidth)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .accessibilityValue(isToday ? "Today" : "")
                }
            }
            .frame(width: columnWidth * CGFloat(days.count), alignment: .leading)
            .clipped()
        }
        .mask(Rectangle().padding(.leading, max(0, pinnedGutterX + gutterWidth)))
    }
}

/// All-day events as bars spanning their day columns, one row per `AllDayLayout` row. The
/// parent leaves it out when the visible days have none.
struct DayGridAllDayStrip: View {
    @Environment(AppModel.self) private var model
    let layout: DayGridLayout
    let geometry: DayGridGeometry
    let now: Date
    let pinnedGutterX: CGFloat
    let visibleDays: Set<Date>
    let onSelect: (CalendarEvent) -> Void

    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 22

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.allDayBlocks) { block in
                let frame = frame(for: block)
                if frame.width > 0 {
                    AllDayBar(
                        block: block, isPast: block.localEnd <= now,
                        protectsDay: model.gridDays.contains { agenda in
                            visibleDays.contains(agenda.day) && agenda.blockingAllDayEvents.contains { $0.id == block.event.id }
                        })
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .onTapGesture {
                            onSelect(block.event)
                        }
                }
            }
            Text("all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
                .frame(width: geometry.gutterWidth, height: CGFloat(layout.allDayRowCount) * rowHeight + 2, alignment: .topTrailing)
                .background(FloridaStyle.paper)
                .offset(x: pinnedGutterX)
        }
        .frame(width: geometry.width, height: CGFloat(layout.allDayRowCount) * rowHeight + 2, alignment: .topLeading)
    }

    /// Where the bar sits in the strip; plain `let`s so the type checker does not have to fold
    /// the chain inside the `ForEach`.
    private func frame(for block: DayGridLayout.AllDayBlock) -> CGRect {
        // A spanning event keeps its title visible when its starting day scrolls off screen.
        let x = max(geometry.x(forDay: block.startDayIndex), pinnedGutterX + geometry.gutterWidth) + 2
        let width = max(0, geometry.x(forDay: block.endDayIndex + 1) - x - 2)
        let y: CGFloat = CGFloat(block.row) * rowHeight + 2
        return CGRect(x: x, y: y, width: width, height: rowHeight - 4)
    }
}

private struct AllDayBar: View {
    let block: DayGridLayout.AllDayBlock
    /// The event's last local day has ended (its stored UTC start would dim it a day early).
    let isPast: Bool
    let protectsDay: Bool

    var body: some View {
        let opacity: Double = isPast ? 0.6 : 1
        let shape = RoundedRectangle(cornerRadius: 4)
        HStack(spacing: 4) {
            if protectsDay {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption2)
            }
            Text(block.title)
        }
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
            .accessibilityValue(protectsDay ? "All day, Protected. \(AllDayBlocking.explanation(for: block.event))" : "All day")
            .accessibilityIdentifier("all-day-event-\(block.event.id)")
            .accessibilityAddTraits(.isButton)
    }
}
