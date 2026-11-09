import FloridaKit
import SwiftUI
import WidgetKit

/// The next event or task block (or the one in progress) as of the entry date; medium shows three.
struct UpNextEntry: TimelineEntry {
    let date: Date
    /// Whether the Lock Screen form counts down to a meeting's start from two minutes out.
    var joinCountdown = true
    /// Blocks still running or starting at/after `date`, by start; at most three.
    let blocks: [WidgetBlock]
    /// False when the shared store could not be opened or read.
    let available: Bool

    static func placeholder(at date: Date) -> UpNextEntry {
        let start = date.addingTimeInterval(15 * 60)
        var event = CalendarEvent(
            id: "placeholder", calendarId: "", googleId: "", summary: "Team standup",
            startAt: start, endAt: start.addingTimeInterval(30 * 60), updatedAt: date)
        event.location = "Room 4"
        return UpNextEntry(date: date, blocks: [WidgetBlock(event: event)], available: true)
    }
}

struct UpNextProvider: TimelineProvider {
    static let horizon: TimeInterval = 6 * 3600
    static let maxEntries = 30
    static let rowsPerEntry = 3

    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry.placeholder(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        let now = Date()
        if context.isPreview {
            completion(UpNextEntry.placeholder(at: now))
            return
        }
        let loaded = WidgetStore.timedBlocks(in: now..<now.addingTimeInterval(Self.horizon))
        completion(Self.entry(at: now, from: loaded))
    }

    /// One entry now plus one at every block start and end within the next six hours, so the
    /// widget flips to the next item exactly when the current one ends, and one two minutes
    /// before each meeting with a link, when the Join countdown starts.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let now = Date()
        let horizon = now.addingTimeInterval(Self.horizon)
        let loaded = WidgetStore.timedBlocks(in: now..<horizon)
        let countdown = WidgetSettings.joinCountdown
        var dates: Set<Date> = [now]
        for block in loaded ?? [] {
            let joinAt = block.joinable && countdown ? [block.start.addingTimeInterval(-WidgetBlock.joinLead)] : []
            for boundary in [block.start, block.end] + joinAt where boundary > now && boundary < horizon {
                dates.insert(boundary)
            }
        }
        let entries = dates.sorted().prefix(Self.maxEntries).map { Self.entry(at: $0, from: loaded) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    static func entry(at date: Date, from loaded: [WidgetBlock]?) -> UpNextEntry {
        guard let loaded else { return UpNextEntry(date: date, blocks: [], available: false) }
        let upcoming = loaded.filter { $0.end > date }.prefix(rowsPerEntry)
        return UpNextEntry(date: date, joinCountdown: WidgetSettings.joinCountdown, blocks: Array(upcoming), available: true)
    }
}

struct UpNextWidget: Widget {
    let kind = "UpNext"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Your next event or scheduled task.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpNextEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                accessory
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .widgetURL(WidgetLinks.agenda)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let block = entry.blocks.first {
                Spacer(minLength: 0)
                UpNextBlockView(block: block, now: entry.date, compact: false)
            } else {
                WidgetPlaceholder(available: entry.available, emptyText: "Nothing coming up")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.blocks.isEmpty {
                WidgetPlaceholder(available: entry.available, emptyText: "Nothing coming up")
            } else {
                ForEach(entry.blocks) { block in
                    UpNextBlockView(block: block, now: entry.date, compact: true)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let block = entry.blocks.first {
                Text(block.title)
                    .font(.headline)
                    .lineLimit(1)
                if entry.joinCountdown && block.isAboutToStart(at: entry.date) {
                    Text("Join · \(Text(timerInterval: entry.date...block.start, countsDown: true))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                } else if block.isInProgress(at: entry.date) {
                    Text("Ends \(Text(block.end, style: .time))")
                        .font(.caption)
                } else {
                    Text(block.start, style: .time)
                        .font(.caption)
                }
                Text(block.kind == .task ? "Task" : "Event")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.available ? "Nothing coming up" : "Open Florida to sync")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("Up Next")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(entry.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// One block in the Up Next widget. The large form (small family) stacks title over time; the
/// compact form (medium family) is a single row with a color bar.
struct UpNextBlockView: View {
    let block: WidgetBlock
    let now: Date
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(block.tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if block.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(block.title)
                        .font(compact ? .subheadline : .headline)
                        .lineLimit(compact ? 1 : 2)
                }
                timeLine
                if !compact, let location = block.location, !location.isEmpty {
                    Text(location)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var timeLine: some View {
        if block.isInProgress(at: now) {
            HStack(spacing: 4) {
                Text("Now ·")
                Text(timerInterval: block.start...block.end, countsDown: true)
                    .monospacedDigit()
                Text("left")
            }
            .font(.caption)
            .foregroundStyle(block.tint)
        } else {
            Text("\(Text(block.start, style: .time)) – \(Text(block.end, style: .time))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
