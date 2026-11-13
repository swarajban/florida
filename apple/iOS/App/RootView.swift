import SwiftUI

/// The three tabs. Also the place where the app reacts to the scene phase (sync on becoming
/// active) and to widget deep links: `florida://agenda` shows today, `florida://tasks` the tasks.
/// The tab on screen is `model.selectedTab`, so the wordmark on any tab can show today's agenda.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: Bindable(model).selectedTab) {
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
        .tint(FloridaStyle.ink)
        .toggleStyle(SystemGreenSwitchStyle())
        .onAppear {
            if model.needsSetup, LaunchOptions.initialTab == nil {
                model.selectedTab = .settings
            }
        }
        .sensoryFeedback(.success, trigger: model.completionCount)
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
        .onOpenURL { url in
            guard let tab = AppTab(deepLink: url) else { return }
            if tab == .agenda {
                model.showToday()
            } else {
                model.selectedTab = tab
            }
            if tab == .tasks, url.path() == "/new" {
                model.showingQuickAdd = true
            }
        }
        .sheet(isPresented: Bindable(model).showingQuickAdd) {
            QuickAddSheet()
        }
        .modifier(SourceOpenTestHarness())
    }
}

/// The app tint is ink, which is near white in dark mode: a switch tinted with it shows a white
/// knob on a cream track and reads as neither on nor off. Switches keep the system green instead;
/// the toggle itself is otherwise whatever style it would have been.
private struct SystemGreenSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .tint(.green)
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
