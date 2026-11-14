import FloridaKit
import SwiftUI
import WidgetKit

/// Today's remaining agenda: all-day events, then events and task blocks that have not ended yet.
struct TodayEntry: TimelineEntry {
    let date: Date
    let day: Date
    let blocks: [WidgetBlock]
    /// False when the shared store could not be opened or read.
    let available: Bool
    var joinCountdown = true

    static func placeholder(at date: Date) -> TodayEntry {
        let day = WidgetStore.calendar.startOfDay(for: date)
        let samples = [("Design review", 10, 11), ("Lunch with Sam", 12, 13), ("Write weekly update", 14, 15)]
        let blocks = samples.map { title, startHour, endHour in
            let start = WidgetStore.calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day) ?? day
            let end = WidgetStore.calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day) ?? start
            return WidgetBlock(event: CalendarEvent(
                id: title, calendarId: "", googleId: "", summary: title,
                startAt: start, endAt: end, updatedAt: date))
        }
        return TodayEntry(date: date, day: day, blocks: blocks, available: true)
    }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry.placeholder(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let now = Date()
        if context.isPreview {
            completion(TodayEntry.placeholder(at: now))
            return
        }
        completion(Self.entry(at: now, day: WidgetStore.calendar.startOfDay(for: now), from: WidgetStore.agenda(for: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        completion(Self.timeline(at: now, from: WidgetStore.agenda(for: now)))
    }

    /// Start/end boundaries keep "Now" and finished rows correct without waiting for a reload.
    /// A midnight entry clears yesterday even if WidgetKit delays the next store read.
    static func timeline(
        at now: Date, from loaded: [WidgetBlock]?, calendar: Calendar = WidgetStore.calendar
    ) -> Timeline<TodayEntry> {
        let day = calendar.startOfDay(for: now)
        let midnight = calendar.date(byAdding: .day, value: 1, to: day)!
        let window = min(now.addingTimeInterval(6 * 3600), midnight)
        var dates: Set<Date> = [now, window]
        for block in loaded ?? [] where !block.allDay {
            for boundary in [block.start.addingTimeInterval(-WidgetBlock.joinLead), block.start, block.end]
                where boundary > now && boundary < window {
                dates.insert(boundary)
            }
        }
        let entries = dates.sorted().map { entry(at: $0, day: day, from: loaded, calendar: calendar) }
        return Timeline(entries: entries, policy: .after(min(now.addingTimeInterval(30 * 60), midnight)))
    }

    static func entry(
        at date: Date, day: Date, from loaded: [WidgetBlock]?, calendar: Calendar = WidgetStore.calendar
    ) -> TodayEntry {
        let currentDay = calendar.startOfDay(for: date)
        guard let loaded else { return TodayEntry(date: date, day: currentDay, blocks: [], available: false) }
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: currentDay)!
        let remaining = currentDay == day
            ? loaded.filter { $0.allDay || ($0.end > date && $0.start < endOfDay) }.sorted(by: WidgetBlock.byStart)
            : []
        return TodayEntry(
            date: date, day: currentDay, blocks: remaining, available: true,
            joinCountdown: WidgetSettings.joinCountdown)
    }
}

struct TodayWidget: Widget {
    let kind = "Today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Today's remaining events and scheduled tasks.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        TodayAgendaView(entry: entry, compact: family == .systemSmall)
            .widgetURL(WidgetLinks.agenda)
            .containerBackground(.fill.tertiary, for: .widget)
            .privacySensitive()
    }
}

struct TodayAgendaView: View {
    @ScaledMetric(relativeTo: .caption) private var rowHeight = 24.0
    @ScaledMetric(relativeTo: .caption2) private var headerHeight = 26.0
    let entry: TodayEntry
    let compact: Bool

    var body: some View {
        GeometryReader { geometry in
            let limit = max(1, Int((geometry.size.height - headerHeight) / rowHeight))
            VStack(alignment: .leading, spacing: 0) {
                header(hidden: max(0, entry.blocks.count - limit))
                    .frame(height: headerHeight, alignment: .top)
                if entry.blocks.isEmpty {
                    WidgetPlaceholder(available: entry.available, emptyText: "Nothing left today")
                } else {
                    ForEach(entry.blocks.prefix(limit)) { block in
                        TodayRow(block: block, now: entry.date, compact: compact)
                            .frame(height: rowHeight)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func header(hidden: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(entry.day, format: compact
                 ? .dateTime.month(.abbreviated).day()
                 : .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1)
                .widgetAccentable()
            Spacer(minLength: 4)
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !compact {
                Link(destination: WidgetLinks.newTask) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .frame(width: 32, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .widgetAccentable()
                .accessibilityLabel("Add task")
            }
        }
        .lineLimit(1)
    }
}

/// One-line rows leave the title most of the width. Shape, not just color, separates tasks.
struct TodayRow: View {
    @ScaledMetric(relativeTo: .caption2) private var timeWidth = 58.0
    let block: WidgetBlock
    let now: Date
    var compact = false

    private var active: Bool { !block.allDay && block.isInProgress(at: now) }

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if block.allDay {
                    Text("All day")
                } else if active {
                    Text("Now")
                        .fontWeight(.semibold)
                } else {
                    Text(block.start, style: .time)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(active ? .primary : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: compact ? timeWidth * 42 / 58 : timeWidth, alignment: .leading)
            Group {
                if block.kind == .task {
                    Image(systemName: block.pinned ? "pin.fill" : "circle")
                        .font(.system(size: 9, weight: .medium))
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .frame(width: 3, height: 13)
                }
            }
            .foregroundStyle(block.tint)
            .frame(width: 10)
            .widgetAccentable()
            Text(block.title)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(block.title), \(block.kind == .task ? "task" : "event")")
        .accessibilityValue(block.allDay ? "All day" : "\(active ? "Now, " : "")\(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened))")
    }
}
