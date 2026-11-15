import FloridaKit
import SwiftUI

/// The three tabs. Also the place where the app reacts to the scene phase (sync on becoming
/// active) and to widget deep links: `florida://agenda` shows today, `florida://tasks` the tasks.
/// The tab on screen is `model.selectedTab`, so the wordmark on any tab can show today's agenda.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var linkedTask: TaskEditorRequest?
    @State private var linkedProject: ProjectEditorRequest?

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
            open(url)
        }
        .sheet(isPresented: Bindable(model).showingQuickAdd) {
            QuickAddSheet()
        }
        .sheet(item: $linkedTask) { request in
            TaskEditorView(request: request)
        }
        .sheet(item: $linkedProject) { request in
            ProjectEditorView(request: request)
        }
        .modifier(SourceOpenTestHarness())
    }

    private func open(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch link {
        case .agenda:
            model.selectedTab = .agenda
            if let date = link.agendaDate(timeZone: model.calendar.timeZone) {
                model.select(day: date)
            } else {
                model.selectToday()
            }
        case .tasks, .newTask:
            model.selectedTab = .tasks
            model.showingQuickAdd = link == .newTask
        case .task(let id):
            model.selectedTab = .tasks
            if let task = model.task(id: id.uuidString.lowercased()) {
                linkedTask = TaskEditorRequest(task: task, isNew: false)
            }
        case .project(let id):
            model.selectedTab = .tasks
            if let project = try? model.database?.project(id: id.uuidString.lowercased()), project.deletedAt == nil {
                linkedProject = ProjectEditorRequest(project: project, isNew: false)
            }
        case .settings:
            model.selectedTab = .settings
        }
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
}
