import FloridaKit
import SwiftUI
import WidgetKit

@main
struct FloridaWidgets: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
    }
}

struct UpNextEntry: TimelineEntry {
    let date: Date
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(UpNextEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let now = Date()
        let refresh = now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [UpNextEntry(date: now)], policy: .after(refresh)))
    }
}

struct UpNextWidgetView: View {
    let entry: UpNextEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Up Next")
                .font(.headline)
            Text(entry.date, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct UpNextWidget: Widget {
    let kind = "UpNext"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Your next events and tasks.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
