import SwiftUI

enum SettingsTab: Hashable {
    case server, calendars, categories, schedules, feel
}

/// The ⌘, window: server settings, the Google calendars to mirror, categories, schedules, and
/// the small touches that can be turned off.
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
            SchedulesSettingsView()
                .tabItem {
                    Label("Schedules", systemImage: "clock")
                }
                .tag(SettingsTab.schedules)
            FeelSettingsView()
                .tabItem {
                    Label("Feel", systemImage: "sparkles")
                }
                .tag(SettingsTab.feel)
        }
        .frame(width: 680, height: 520)
        .onAppear {
            model.start()
        }
    }
}
