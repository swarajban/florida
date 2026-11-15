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
    let compactsVisibleRows: Bool
    let onSelect: (CalendarEvent) -> Void

    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 22
    @State private var selectedOOO: AllDayPresentation.Item?

    var body: some View {
        if compactsVisibleRows {
            singleDayStrip
                .sheet(item: $selectedOOO) { item in
                    CoworkerOOOSheet(events: item.events)
                }
        } else {
            spanningStrip
        }
    }

    private var singleDayStrip: some View {
        let columns = layout.days.indices.map { index in
            AllDayPresentation.items(for: layout.allDayBlocks.filter {
                $0.startDayIndex <= index && $0.endDayIndex >= index
            }.sorted { $0.row < $1.row }.map(\.event)) { id in
                model.calendars.first { $0.id == id }?.summary
            }
        }
        let count = layout.days.indices.filter { visibleDays.contains(layout.days[$0]) }
            .map { columns[$0].count }.max() ?? 0
        return ZStack(alignment: .topLeading) {
            ForEach(layout.days.indices, id: \.self) { index in
                VStack(spacing: 4) {
                    ForEach(columns[index]) { item in
                        Button {
                            if item.isGroup { selectedOOO = item } else { onSelect(item.events[0]) }
                        } label: {
                            if let block = layout.allDayBlocks.first(where: { $0.event.id == item.id }) {
                                AllDayBar(
                                    block: block, isPast: block.localEnd <= now,
                                    protectsDay: model.gridDays.contains { agenda in
                                        agenda.day == layout.days[index] && agenda.blockingAllDayEvents.contains { $0.id == item.id }
                                    }, title: item.isGroup ? item.title : nil)
                                    .frame(height: rowHeight - 4)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(item.isGroup ? "all-day-coworker-ooo" : "all-day-event-\(item.id)")
                    }
                }
                .frame(width: max(0, geometry.columnWidth - 4))
                .offset(x: geometry.x(forDay: index) + 2, y: 2)
                .accessibilityHidden(!visibleDays.contains(layout.days[index]))
            }
            Text(count == 0 ? "" : "all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
                .frame(width: geometry.gutterWidth, height: CGFloat(count) * rowHeight + 2, alignment: .topTrailing)
                .background(FloridaStyle.paper)
                .offset(x: pinnedGutterX)
        }
        .frame(width: geometry.width, height: CGFloat(count) * rowHeight + 2, alignment: .topLeading)
        .clipped()
    }

    private var spanningStrip: some View {
        let rows = Array(0..<layout.allDayRowCount)
        ZStack(alignment: .topLeading) {
            ForEach(layout.allDayBlocks) { block in
                let frame = frame(for: block, rows: rows)
                if frame.width > 0 {
                    AllDayBar(
                        block: block, isPast: block.localEnd <= now,
                        protectsDay: model.gridDays.contains { agenda in
                            visibleDays.contains(agenda.day) && agenda.blockingAllDayEvents.contains { $0.id == block.event.id }
                        })
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .accessibilityHidden(!layout.days[block.startDayIndex...block.endDayIndex].contains { visibleDays.contains($0) })
                        .onTapGesture {
                            onSelect(block.event)
                        }
                }
            }
            Text(rows.isEmpty ? "" : "all-day")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
                .frame(width: geometry.gutterWidth, height: CGFloat(rows.count) * rowHeight + 2, alignment: .topTrailing)
                .background(FloridaStyle.paper)
                .offset(x: pinnedGutterX)
        }
        .frame(width: geometry.width, height: CGFloat(rows.count) * rowHeight + 2, alignment: .topLeading)
        .clipped()
    }

    /// Where the bar sits in the strip; plain `let`s so the type checker does not have to fold
    /// the chain inside the `ForEach`.
    private func frame(for block: DayGridLayout.AllDayBlock, rows: [Int]) -> CGRect {
        // A spanning event keeps its title visible when its starting day scrolls off screen.
        let x = max(geometry.x(forDay: block.startDayIndex), pinnedGutterX + geometry.gutterWidth) + 2
        let width = max(0, geometry.x(forDay: block.endDayIndex + 1) - x - 2)
        let y: CGFloat = CGFloat(rows.firstIndex(of: block.row) ?? block.row) * rowHeight + 2
        return CGRect(x: x, y: y, width: width, height: rowHeight - 4)
    }
}

private struct AllDayBar: View {
    let block: DayGridLayout.AllDayBlock
    /// The event's last local day has ended (its stored UTC start would dim it a day early).
    let isPast: Bool
    let protectsDay: Bool
    var title: String? = nil

    var body: some View {
        let opacity: Double = isPast ? 0.6 : 1
        let shape = RoundedRectangle(cornerRadius: 4)
        HStack(spacing: 4) {
            if protectsDay {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption2)
            }
            Text(title ?? block.title)
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
            .accessibilityLabel(title ?? block.title)
            .accessibilityValue(protectsDay ? "All day, Protected. \(AllDayBlocking.explanation(for: block.event))" : "All day")
            .accessibilityIdentifier("all-day-event-\(block.event.id)")
            .accessibilityAddTraits(.isButton)
    }
}
