import FloridaKit
import SwiftUI

/// A calendar event in the day timeline: time column, title, location.
struct EventRow: View {
    let event: CalendarEvent
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeColumn(start: event.startAt, end: event.endAt)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(AgendaItem.event(event).title)
                    .font(.body)
                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if event.htmlLink.flatMap(URL.init(string:)) != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(AgendaItem.event(event).isOver(at: now) ? 0.55 : 1)
    }
}

/// A scheduled task block in the day timeline: time column, project color, title, pin glyph.
struct BlockRow: View {
    let block: ScheduledBlock
    let project: Project?
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeColumn(start: block.placement.startAt, end: block.placement.endAt)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.project(project))
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
                    Text(project?.name ?? "No project")
                    Text("·")
                    Text(Formatting.duration(minutes: block.task.durationMinutes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .opacity(AgendaItem.block(block).isOver(at: now) ? 0.55 : 1)
    }
}

/// An all-day event in the section above the timeline.
struct AllDayEventRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
            Text(AgendaItem.event(event).title)
            Spacer(minLength: 0)
            if let location = event.location, !location.isEmpty {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
                .frame(width: 64, alignment: .trailing)
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
private struct TimeColumn: View {
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
        .frame(width: 64, alignment: .trailing)
    }
}
