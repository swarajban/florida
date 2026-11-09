import FloridaKit
import SwiftUI

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
                    FloridaWordmark(height: 26)
                    Spacer()
                    Text("⌘K  Quick add")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
