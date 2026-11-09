import SwiftUI

/// The three tabs. Also the place where the app reacts to the scene phase (sync on becoming
/// active) and to widget deep links: `florida://agenda` shows today, `florida://tasks` the tasks.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = LaunchOptions.initialTab ?? .agenda

    var body: some View {
        TabView(selection: $selectedTab) {
            AgendaView()
                .tabItem { Label("Agenda", systemImage: "calendar") }
                .tag(AppTab.agenda)
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(AppTab.tasks)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(AppTab.settings)
                .badge((model.storeError == nil && model.lastError == nil ? 0 : 1) + model.rejectedChanges.count)
        }
        .onAppear {
            if model.needsSetup, LaunchOptions.initialTab == nil {
                selectedTab = .settings
            }
        }
        .sensoryFeedback(.success, trigger: model.completionCount)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
        .onOpenURL { url in
            guard let tab = AppTab(deepLink: url) else { return }
            selectedTab = tab
            if tab == .agenda {
                model.selectToday()
            }
        }
    }
}

enum AppTab: String, Hashable {
    case agenda, tasks, settings

    /// `florida://<tab>` as sent by the widgets' `widgetURL`.
    init?(deepLink url: URL) {
        guard url.scheme == "florida", let host = url.host(), let tab = AppTab(rawValue: host) else { return nil }
        self = tab
    }
}
