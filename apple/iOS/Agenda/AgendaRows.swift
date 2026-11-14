import FloridaKit
import SwiftUI

/// A calendar event in the day timeline: time column, then a card filled in the calendar's color
/// with its bar, title, location, and "Day 2 of 3" when it spans several days.
///
/// The card is what tells a meeting from a task at a glance. An event is fixed, so it is a
/// solid block of its calendar's color, as on a calendar; a task block is the scheduler's
/// suggestion, so `BlockRow` leaves it open: no fill, a dashed bar, an unticked circle and
/// quieter times.
struct EventRow: View {
    /// The fill behind an event, as a share of its calendar color.
    static let fillOpacity = 0.16

    let event: CalendarEvent
    let style: EventStyle
    let continuation: String?
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeColumn(start: event.startAt, end: event.endAt)
                .padding(.top, Self.cardPadding)
            HStack(alignment: .top, spacing: 12) {
                EventBar(style: style)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgendaItem.event(event).title)
                        .font(.body.weight(.medium))
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
                .padding(.vertical, Self.cardPadding)
                Spacer(minLength: 0)
                if event.joinURL != nil {
                    Image(systemName: "video")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, Self.cardPadding + 3)
                        .accessibilityLabel("Has a meeting link")
                }
            }
            .padding(.trailing, 10)
            .background(style.fill.opacity(Self.fillOpacity))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 3)
        .opacity(AgendaItem.event(event).isOver(at: now) ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(style.accessibilityDescription)
    }

    /// Space above and below the text inside the card. With the row's own padding it keeps an
    /// event row as tall as a task row.
    private static let cardPadding: CGFloat = 6
}

/// A scheduled task block in the day timeline: time column, category color, an unticked circle,
/// title, pin glyph. With `showsProgress`, the block in progress fills left to right in its
/// category color and says how long is left.
///
/// A block is where the scheduler suggests doing the task, not an appointment, and it may move
/// on the next run. So it reads lighter than an `EventRow`: no card, times in the secondary
/// color and a dashed bar. A pinned block is a time the user chose: its bar is solid and its
/// times are as dark as an event's.
struct BlockRow: View {
    /// Where the block's content starts: the time column, the bar, and the spacing on both sides
    /// of it.
    static let titleInset: CGFloat = TimeColumn.width + 12 + TaskBar.width + 12

    let block: ScheduledBlock
    let category: TaskCategory?
    let now: Date
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeColumn(start: block.placement.startAt, end: block.placement.endAt, isSuggestion: !block.placement.pinned)
            TaskBar(color: Color.category(category), isSuggestion: !block.placement.pinned)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // A mark, not a control: the whole row is one button that opens the task.
                Image(systemName: block.task.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(Color.category(category))
                    .accessibilityHidden(true)
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
                    // No priority glyph here: the agenda is about when, the Tasks tab about how urgent.
                    HStack(spacing: 4) {
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
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            if let fraction {
                GeometryReader { proxy in
                    Color.category(category)
                        .opacity(0.13)
                        .frame(width: proxy.size.width * fraction)
                        .animation(.linear(duration: 0.6), value: fraction)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
    let protectsDay: Bool

    var body: some View {
        HStack(spacing: 10) {
            EventBar(style: style)
                .frame(height: 18)
            if protectsDay {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
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
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue("All day, \(style.accessibilityDescription)\(protectsDay ? ", Protected. " + AllDayBlocking.explanation(for: event) : "")")
    }
}

extension View {
    /// Starts a timeline row's separator at the row's leading edge, for a row that begins with a
    /// `TimeColumn`. Left alone, the list starts the line at the row's text: the time for most
    /// rows, but an event's location `Label` moves it under the location, so the lines down a
    /// day began in different places.
    func timelineSeparator() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
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

/// The bar in front of a task block, in its category color: dashed while the time is the
/// scheduler's suggestion, solid once the task is pinned there.
struct TaskBar: View {
    static let width: CGFloat = 3

    let color: Color
    let isSuggestion: Bool

    var body: some View {
        Group {
            if isSuggestion {
                Line()
                    .stroke(color, style: StrokeStyle(lineWidth: Self.width, dash: [5, 3]))
            } else {
                RoundedRectangle(cornerRadius: Self.width / 2)
                    .fill(color)
            }
        }
        .frame(width: Self.width)
        .accessibilityHidden(true)
    }

    /// Top to bottom down the middle of the bar.
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }
}

/// Start over end, right-aligned, in a fixed-width column so titles line up.
/// Wide enough for "10:15 AM" at the default text size; larger sizes shrink rather than wrap.
/// `isSuggestion` is for a task block the scheduler may still move: its times step back one
/// level, so the fixed times of meetings stand out down the column.
struct TimeColumn: View {
    static let width: CGFloat = 76

    let start: Date?
    let end: Date?
    var isSuggestion = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let start {
                let time = Text(start, style: .time)
                    .font(.subheadline.monospacedDigit())
                // Otherwise untouched, so it takes the row's own style (a ghost row's is faint).
                if isSuggestion {
                    time.foregroundStyle(.secondary)
                } else {
                    time
                }
            }
            if let end {
                Text(end, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSuggestion ? .tertiary : .secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: Self.width, alignment: .trailing)
    }
}
