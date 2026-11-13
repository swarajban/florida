import FloridaKit
import SwiftUI

/// The task editor's rows for projects and parallel work: the project the task belongs to, the
/// attention it takes, and, for a saved task that is on the plan, "Why here?".
///
/// "Why here?" asks the server's model on a tap. The answer, or the reason there is none, shows
/// under the row, and the rest of the form stays usable while it loads.
struct TaskPlanSection: View {
    /// Where a "Why here?" request stands.
    enum Explanation: Equatable {
        case idle
        case loading
        case answer(String)
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @Binding var task: TaskItem
    /// The task as the editor opened it.
    let original: TaskItem
    let isNew: Bool
    /// Held by the editor, so the answer is still there after the row scrolls away and back.
    @Binding var explanation: Explanation

    var body: some View {
        Section {
            Picker("Project", selection: $task.projectId) {
                Text("None").tag(String?.none)
                if let missingProjectId {
                    // Keeps the selection valid while the task still names a project that is gone.
                    Text("Deleted project").tag(String?.some(missingProjectId))
                }
                ForEach(offeredSections) { section in
                    Section(section.status.label) {
                        ForEach(section.projects) { project in
                            Text(project.name).tag(String?.some(project.id))
                        }
                    }
                }
            }
            .accessibilityIdentifier("task-project")
            Picker("Attention", selection: $task.attention) {
                Text("Follow project").tag(TaskAttention?.none)
                ForEach(TaskAttention.allCases, id: \.self) { attention in
                    Text(attention.displayName).tag(TaskAttention?.some(attention))
                }
            }
            .accessibilityIdentifier("task-attention")
        } header: {
            Text("Project")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let attentionNote {
                    Text(attentionNote)
                }
                Text(PlanText.parallelFootnote)
            }
        }

        if task.someday {
            Section {
                Label("Someday", systemImage: "tray")
                    .accessibilityIdentifier("task-plan-someday")
            }
        } else if let summary = scheduleSummary {
            Section {
                Button {
                    askWhy()
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Why here?")
                                Text(summary.headline(now: Date(), calendar: model.calendar))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        Spacer()
                        if explanation == .loading {
                            ProgressView()
                        }
                    }
                }
                .disabled(explanation == .loading)
                .accessibilityHint("Asks the server why the task is planned at this time")
                .accessibilityIdentifier("task-why")

                switch explanation {
                case .idle, .loading:
                    EmptyView()
                case .answer(let text):
                    Text(text)
                        .font(.subheadline)
                        .accessibilityIdentifier("task-why-answer")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("task-why-error")
                }
            }
        }
    }

    // MARK: - Project

    /// `model.projectSections` without the done projects, except the one the task was opened with.
    private var offeredSections: [ProjectSection] {
        model.projectSections.compactMap { section -> ProjectSection? in
            var section = section
            section.projects.removeAll { $0.status == .done && $0.id != original.projectId }
            return section.projects.isEmpty ? nil : section
        }
    }

    /// The task's project id when the list has no project for it (deleted since the task was read).
    private var missingProjectId: String? {
        guard let id = task.projectId else { return nil }
        let offered = offeredSections.contains { $0.projects.contains { $0.id == id } }
        return offered ? nil : id
    }

    // MARK: - Attention

    /// What the attention comes to when the picker alone does not say: "Following Infosec audit:
    /// Can run in parallel" while it follows the project, and that a pinned task has its time to
    /// itself whatever is chosen.
    private var attentionNote: String? {
        let project = model.project(id: task.projectId)
        let effective = task.attention(in: project).displayName
        if task.pinnedStart != nil, task.attention != TaskAttention.full {
            return "Pinned to a time: \(effective)"
        }
        guard task.attention == nil else { return nil }
        if let project {
            return "Following \(project.name): \(effective)"
        }
        return "No project: \(effective)"
    }

    // MARK: - Why here?

    /// Where the saved task is on the plan; nil for a new task, a finished one, and one with no
    /// block, which have no "here" to ask about.
    private var scheduleSummary: TaskScheduleSummary? {
        guard !isNew, original.isOpen, !original.someday, !task.someday,
              model.task(id: original.id)?.someday != true else { return nil }
        let placements = model.placementsByTask[original.id] ?? []
        guard !placements.isEmpty else { return nil }
        return TaskScheduleSummary(
            task: original, placements: placements, unscheduled: model.unscheduledByTask[original.id], now: Date())
    }

    /// Asks about the saved task (the server does not know unsaved edits). Not cancelled when
    /// the sheet closes: the answer then lands in state nobody reads.
    private func askWhy() {
        guard explanation != .loading else { return }
        explanation = .loading
        Task {
            do {
                let answer = try await model.explainPlacement(of: original)
                explanation = .answer(answer)
            } catch {
                explanation = .failed(error.localizedDescription)
            }
        }
    }
}
