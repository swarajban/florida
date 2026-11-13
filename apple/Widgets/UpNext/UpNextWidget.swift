import FloridaKit
import SwiftUI
import WidgetKit

/// Keep the existing kind so installed Up Next widgets adopt the today's-agenda layout.
struct UpNextWidget: Widget {
    let kind = "UpNext"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Agenda")
        .description("Today's remaining events and scheduled tasks.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessory
            } else {
                TodayWidgetView(entry: entry)
            }
        }
        .widgetURL(WidgetLinks.agenda)
        .containerBackground(.fill.tertiary, for: .widget)
        .privacySensitive()
    }

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let block = entry.blocks.first(where: { !$0.allDay }) {
                Text(block.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if entry.joinCountdown && block.isAboutToStart(at: entry.date) {
                    Text("Join · \(Text(timerInterval: entry.date...block.start, countsDown: true))")
                        .font(.caption.monospacedDigit())
                } else if block.isInProgress(at: entry.date) {
                    Text("Ends \(Text(block.end, style: .time))")
                        .font(.caption)
                } else {
                    Text(block.start, style: .time)
                        .font(.caption)
                }
                Text(block.kind == .task ? "Task · Today" : "Event · Today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.available ? "Nothing left today" : "Open Florida to sync")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
