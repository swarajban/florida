import SwiftUI
import WidgetKit

/// The widget extension's entry point. Every widget reads the shared SQLite store in the App
/// Group container and never talks to the server; the app refreshes them after each sync.
@main
struct FloridaWidgets: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        TodayWidget()
        TasksWidget()
    }
}

/// Deep links the widgets open the app with; `RootView` maps them to tabs.
enum WidgetLinks {
    static let agenda = URL(string: "florida://agenda")
    static let tasks = URL(string: "florida://tasks")
}
