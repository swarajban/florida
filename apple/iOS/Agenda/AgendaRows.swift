import FloridaKit
import SwiftUI

/// A calendar event in the day timeline: time column, calendar-colored bar, title, location,
/// and "Day 2 of 3" when it spans several days.
struct EventRow: View {
    let event: CalendarEvent
    let style: EventStyle
    let continuation: String?
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeColumn(start: event.startAt, end: event.endAt)
            EventBar(style: style)
            VStack(alignment: .leading, spacing: 2) {
                Text(AgendaItem.event(event).title)
                    .font(.body)
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let continuation {
                    Text(continuation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if event.joinURL != nil {
                Image(systemName: "video")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has a meeting link")
            }
        }
        .opacity(AgendaItem.event(event).isOver(at: now) ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(style.accessibilityDescription)
    }
}

/// A scheduled task block in the day timeline: time column, category color, title, pin glyph.
/// With `showsProgress`, the block in progress fills left to right in its category color and
/// says how long is left.
struct BlockRow: View {
    let block: ScheduledBlock
    let category: TaskCategory?
    let now: Date
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeColumn(start: block.placement.startAt, end: block.placement.endAt)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.category(category))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if block.placement.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(block.task.title)
                        .font(.body)
                }
                HStack(spacing: 4) {
                    Image(systemName: block.task.priority.symbolName)
                        .foregroundStyle(block.task.priority.tint)
                    Text(category?.name ?? "No category")
                    Text("·")
                    if let minutesLeft {
                        Text("\(minutesLeft) min left")
                            .foregroundStyle(Color.category(category))
                            .fontWeight(.semibold)
                    } else {
                        Text(Formatting.duration(minutes: block.task.durationMinutes))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .leading) {
            if let fraction {
                GeometryReader { proxy in
                    Color.category(category)
                        .opacity(0.13)
                        .frame(width: proxy.size.width * fraction)
                        .animation(.linear(duration: 0.6), value: fraction)
                }
                .padding(.vertical, -6)
                .accessibilityHidden(true)
            }
        }
        .opacity(AgendaItem.block(block).isOver(at: now) ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    /// How much of the block has passed, while it is in progress.
    private var fraction: Double? {
        guard showsProgress, block.task.completedAt == nil, AgendaItem.block(block).isInProgress(at: now) else { return nil }
        let total = block.placement.endAt.timeIntervalSince(block.placement.startAt)
        guard total > 0 else { return nil }
        return min(1, max(0, now.timeIntervalSince(block.placement.startAt) / total))
    }

    /// Whole minutes until the block ends, rounded up, while it is in progress.
    private var minutesLeft: Int? {
        guard fraction != nil else { return nil }
        return Int((block.placement.endAt.timeIntervalSince(now) / 60).rounded(.up))
    }
}

/// An all-day event in the section above the timeline.
struct AllDayEventRow: View {
    let event: CalendarEvent
    let style: EventStyle
    let continuation: String?

    var body: some View {
        HStack(spacing: 10) {
            EventBar(style: style)
                .frame(height: 18)
            Text(AgendaItem.event(event).title)
            if let continuation {
                Text(continuation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let location = event.location, !location.isEmpty {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("All day, \(style.accessibilityDescription)")
    }
}

/// The red "now" line slotted between rows on today's timeline.
struct NowMarker: View {
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(now, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.red)
                .frame(width: TimeColumn.width, alignment: .trailing)
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(.red)
                .frame(height: 1)
        }
        .listRowSeparator(.hidden)
        .accessibilityLabel("Now")
    }
}

/// Start over end, right-aligned, in a fixed-width column so titles line up.
/// Wide enough for "10:15 AM" at the default text size; larger sizes shrink rather than wrap.
struct TimeColumn: View {
    static let width: CGFloat = 76

    let start: Date?
    let end: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let start {
                Text(start, style: .time)
                    .font(.subheadline.monospacedDigit())
            }
            if let end {
                Text(end, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: Self.width, alignment: .trailing)
    }
}
