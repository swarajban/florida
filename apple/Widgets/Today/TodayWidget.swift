import FloridaKit
import SwiftUI
import WidgetKit

/// Today's remaining agenda: all-day events, then events and task blocks that have not ended yet.
struct TodayEntry: TimelineEntry {
    let date: Date
    /// Start of the day the entry describes.
    let day: Date
    /// Rows still relevant at `date`: all-day events plus timed items that end after `date`.
    let blocks: [WidgetBlock]
    /// False when the shared store could not be opened or read.
    let available: Bool

    static func placeholder(at date: Date) -> TodayEntry {
        let calendar = WidgetStore.calendar
        let day = calendar.startOfDay(for: date)
        let samples = [("Design review", 10, 11), ("Lunch with Sam", 12, 13), ("Write weekly update", 14, 15)]
        let blocks = samples.map { title, startHour, endHour in
            let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day) ?? day
            let end = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day) ?? start
            let event = CalendarEvent(
                id: title, calendarId: "", googleId: "", summary: title, startAt: start, endAt: end, updatedAt: date)
            return WidgetBlock(event: event)
        }
        return TodayEntry(date: date, day: day, blocks: blocks, available: true)
    }
}

struct TodayProvider: TimelineProvider {
    static let hours = 6

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

    /// Hourly entries for the next six hours (stopping at midnight, when the day changes), each
    /// dropping the items that have ended by then; WidgetKit is asked back after the next hour.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let calendar = WidgetStore.calendar
        let day = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: day) ?? now.addingTimeInterval(86_400)
        let loaded = WidgetStore.agenda(for: now)
        var entries = [Self.entry(at: now, day: day, from: loaded)]
        for hour in 1...Self.hours {
            let date = now.addingTimeInterval(TimeInterval(hour) * 3600)
            guard date < endOfDay else { break }
            entries.append(Self.entry(at: date, day: day, from: loaded))
        }
        let nextHour = min(now.addingTimeInterval(3600), endOfDay)
        completion(Timeline(entries: entries, policy: .after(nextHour)))
    }

    static func entry(at date: Date, day: Date, from loaded: [WidgetBlock]?) -> TodayEntry {
        guard let loaded else { return TodayEntry(date: date, day: day, blocks: [], available: false) }
        let remaining = loaded.filter { $0.allDay || $0.end > date }
        return TodayEntry(date: date, day: day, blocks: remaining, available: true)
    }
}

struct TodayWidget: Widget {
    let kind = "Today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("What is left on today's calendar.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private var rowLimit: Int {
        family == .systemLarge ? 10 : 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if entry.blocks.isEmpty {
                WidgetPlaceholder(available: entry.available, emptyText: "Nothing left today")
            } else {
                ForEach(entry.blocks.prefix(rowLimit)) { block in
                    TodayRow(block: block, now: entry.date)
                }
                if entry.blocks.count > rowLimit {
                    Text("\(entry.blocks.count - rowLimit) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 56)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(WidgetLinks.agenda)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.day.formatted(.dateTime.weekday(.wide)))
                .font(.headline)
            Text(entry.day.formatted(.dateTime.month(.abbreviated).day()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(entry.blocks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

/// Time column, color bar, title; task blocks are tinted with their project color.
struct TodayRow: View {
    let block: WidgetBlock
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if block.allDay {
                    Text("all day")
                } else {
                    Text(block.start, style: .time)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .trailing)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(block.tint)
                .frame(width: 3, height: 16)
            if block.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(block.title)
                .font(.caption)
                .fontWeight(block.isInProgress(at: now) ? .semibold : .regular)
                .foregroundStyle(block.kind == .task ? block.tint : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
