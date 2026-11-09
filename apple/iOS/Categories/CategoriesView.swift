import FloridaKit
import SwiftUI

/// Categories, pushed from the Tasks tab: Inbox first (fixed), then the others in their order.
/// Tap to edit; Edit to reorder; swipe or the editor to delete (after a confirmation that says
/// where the tasks go); + to add.
struct CategoriesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CategoryEditorTarget?
    @State private var deleting: TaskCategory?

    var body: some View {
        List {
            if let inbox = model.inbox {
                Section {
                    row(inbox)
                        .moveDisabled(true)
                } footer: {
                    Text("New tasks land in Inbox until you file them. It can't be renamed or deleted.")
                }
            }
            Section {
                ForEach(others) { category in
                    row(category)
                        .swipeActions(edge: .trailing) {
                            Button {
                                deleting = category
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        // On the row, so the dialog opens next to it rather than at the list's edge.
                        .categoryDeleteConfirmation($deleting.only(category))
                }
                .onMove { source, destination in
                    model.moveCategories(fromOffsets: source, toOffset: destination)
                }
            } footer: {
                if others.isEmpty {
                    Text("Add categories such as Work or Personal; each one follows a schedule's hours.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(others.count < 2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = .new
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add category")
            }
        }
        .sheet(item: $editing) { target in
            CategoryEditorView(target: target)
        }
        .toastOverlay()
    }

    private var others: [TaskCategory] {
        model.categories.filter { !$0.isInbox }
    }

    private func row(_ category: TaskCategory) -> some View {
        Button {
            editing = .edit(category)
        } label: {
            HStack(spacing: 12) {
                if category.isInbox {
                    Image(systemName: "tray.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 14)
                } else {
                    Circle()
                        .fill(Color.category(category))
                        .frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .foregroundStyle(.primary)
                    Text(subtitle(category))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityHint("Edits the category")
    }

    /// "Work hours · 4 open tasks".
    private func subtitle(_ category: TaskCategory) -> String {
        let schedule = model.schedule(id: category.scheduleId)?.name ?? "Unknown schedule"
        let count = model.openTasks.filter { $0.categoryId == category.id }.count
        return "\(schedule) · \(count) open \(count == 1 ? "task" : "tasks")"
    }
}

/// What the category sheet is for.
enum CategoryEditorTarget: Identifiable, Hashable {
    case new
    case edit(TaskCategory)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let category): category.id
        }
    }
}

extension View {
    /// Asks before deleting a category, saying how many open tasks move to Inbox. Put it on the
    /// row or button that sets `category`: the dialog opens anchored to the view it modifies.
    func categoryDeleteConfirmation(_ category: Binding<TaskCategory?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(CategoryDeleteConfirmation(category: category, onDeleted: onDeleted))
    }
}

private struct CategoryDeleteConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var category: TaskCategory?
    let onDeleted: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete “\(category?.name ?? "")”?",
            isPresented: Binding(get: { category != nil }, set: { if !$0 { category = nil } }),
            titleVisibility: .visible,
            presenting: category
        ) { category in
            Button("Delete Category", role: .destructive) {
                do {
                    try model.deleteCategory(category)
                    onDeleted()
                } catch {
                    model.showToast(Toast(message: error.localizedDescription, systemImage: "exclamationmark.triangle.fill", style: .error))
                }
            }
        } message: { category in
            let count = model.openTasks.filter { $0.categoryId == category.id }.count
            Text(count == 0 ? "It has no open tasks." : "Its \(count) open \(count == 1 ? "task moves" : "tasks move") to Inbox.")
        }
    }
}
