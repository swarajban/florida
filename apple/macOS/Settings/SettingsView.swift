import SwiftUI

enum SettingsTab: Hashable {
    case server, calendars, categories, routine, feel
}

/// The ⌘, window: server settings, the Google calendars to mirror, categories, the read-only
/// routine, and the small touches that can be turned off.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ServerSettingsForm()
                .tabItem {
                    Label("Server", systemImage: "server.rack")
                }
                .tag(SettingsTab.server)
            CalendarsSettingsView()
                .tabItem {
                    Label("Calendars", systemImage: "calendar")
                }
                .tag(SettingsTab.calendars)
            CategoriesSettingsView()
                .tabItem {
                    Label("Categories", systemImage: "folder")
                }
                .tag(SettingsTab.categories)
            RoutineSettingsView()
                .tabItem {
                    Label("Routine", systemImage: "calendar.day.timeline.left")
                }
                .tag(SettingsTab.routine)
            FeelSettingsView()
                .tabItem {
                    Label("Feel", systemImage: "sparkles")
                }
                .tag(SettingsTab.feel)
        }
        .accessibilityIdentifier("settings-tabs")
        .frame(width: 680, height: 520)
        .onAppear {
            model.start()
        }
    }
}
