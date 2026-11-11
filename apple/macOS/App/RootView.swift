import FloridaKit
import SwiftUI

/// Projects, the brief and "Why here?". A modifier of its own: with these in `RootView.body` the
/// chain there is too long for the type checker.
private struct PlanSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.isProjectsOpen) {
                ProjectsSheet()
            }
            .sheet(isPresented: $model.isBriefOpen) {
                BriefSheet()
            }
            .sheet(item: $model.explanation) { _ in
                ExplanationSheet()
            }
    }
}

/// The main window: calendar on the left, tasks on the right, a status bar below, and the
/// palette and help as overlays. Shows the setup screen until a server token is saved.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            content
            GhostView()
            if model.isPaletteOpen {
                paletteOverlay
            }
            if model.isHelpOpen {
                HelpOverlayView()
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(FloridaStyle.paper)
        .background(KeyEventMonitorView(model: model))
        .sheet(item: $model.editorTask) { task in
            TaskEditorSheet(task: task, isNew: model.tasksById[task.id] == nil)
        }
        .sheet(isPresented: $model.isGoToDateOpen) {
            GoToDateView()
        }
        .sheet(isPresented: $model.isNewCategoryOpen) {
            NewCategorySheet()
        }
        .sheet(item: $model.doneForNow) { request in
            DoneForNowSheet(request: request)
        }
        .sheet(item: $model.eventEditor) { request in
            EventEditorSheet(event: request.event, isNew: request.isNew)
        }
        .modifier(PlanSheets())
        .confirmationDialog(
            "Delete this occurrence and stop repeating?",
            isPresented: Binding(
                get: { model.recurringTaskToDelete != nil },
                set: { if !$0 { model.recurringTaskToDelete = nil } }),
            titleVisibility: .visible, presenting: model.recurringTaskToDelete
        ) { task in
            Button("Delete and Stop Repeating", role: .destructive) {
                model.deleteTask(task)
                model.recurringTaskToDelete = nil
            }
            Button("Cancel", role: .cancel) { model.recurringTaskToDelete = nil }
        } message: { _ in
            Text("This and future unfinished occurrences will be removed. Completed history is kept.")
        }
        .confirmationDialog(
            "Delete this event?",
            isPresented: Binding(
                get: { model.eventToDelete != nil },
                set: { if !$0 { model.eventToDelete = nil } }),
            titleVisibility: .visible, presenting: model.eventToDelete
        ) { event in
            Button("Delete Event", role: .destructive) {
                model.delete(event: event)
                model.eventToDelete = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.eventToDelete = nil }
        } message: { event in
            Text("\(AppModel.quoted(AppModel.title(of: event))) is deleted from Google Calendar too. This cannot be undone.")
        }
        .confirmationDialog(
            model.eventMove.map(model.moveQuestion) ?? "Move this event?",
            isPresented: Binding(
                get: { model.eventMove != nil },
                set: { if !$0 { model.cancelEventMove() } }),
            titleVisibility: .visible, presenting: model.eventMove
        ) { request in
            Button(request.repeats ? "This Event" : "Move Event") {
                model.eventMove = nil
                model.move(event: request.event, toStart: request.start)
            }
            .keyboardShortcut(.defaultAction)
            if request.canMoveSeries {
                Button("All Events") {
                    model.eventMove = nil
                    model.moveSeries(of: request.event, toStart: request.start)
                }
            }
            Button("Cancel", role: .cancel) { model.cancelEventMove() }
        } message: { request in
            Text(model.moveMessage(request))
        }
        .onChange(of: model.settingsRequest) {
            openSettings()
        }
        .onAppear {
            model.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.startupError {
            ContentUnavailableView(
                "Florida can't open its local store", systemImage: "externaldrive.badge.exclamationmark",
                description: Text(error))
        } else if model.config == nil {
            SetupView()
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        model.perform(.today)
                    } label: {
                        FloridaWordmark(height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help("Go to today (\(MacKeymap.default.shortcut(for: .core(.today))))")
                    .accessibilityLabel("Go to today")
                    Spacer()
                    Button {
                        model.run(.showBrief)
                    } label: {
                        Label("Brief", systemImage: "sun.horizon")
                    }
                    .help("Today's brief and the weekly review (\(MacKeymap.default.shortcut(for: .showBrief)))")
                    .accessibilityIdentifier("open-brief")
                    Button {
                        model.run(.showProjects)
                    } label: {
                        Label("Projects", systemImage: PlanText.projectSymbol)
                    }
                    .help("Projects (\(MacKeymap.default.shortcut(for: .showProjects)))")
                    .accessibilityIdentifier("open-projects")
                    Text("⌘K  Commands")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        CalendarHeaderBar()
                        Divider()
                        CalendarContainerView()
                    }
                    if model.isTasksPaneVisible {
                        Divider()
                        TaskPaneView()
                    }
                }
                Divider()
                StatusBarView()
            }
        }
    }

    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    model.closePalette()
                }
            CommandPaletteView()
                .padding(.top, 72)
        }
    }
}
