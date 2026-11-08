import SwiftUI

/// The ⌘, window: server settings and the Google calendars to mirror.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            ServerSettingsForm()
                .tabItem {
                    Label("Server", systemImage: "server.rack")
                }
            CalendarsSettingsView()
                .tabItem {
                    Label("Calendars", systemImage: "calendar")
                }
        }
        .frame(width: 540, height: 440)
        .onAppear {
            model.start()
        }
    }
}
