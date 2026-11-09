import FloridaKit
import SwiftUI

/// Sheet to add or edit a category: name, color, and the schedule whose hours its tasks follow.
/// Inbox keeps its name and cannot be deleted. Errors show in place; nothing waits on the server.
struct CategoryEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: CategoryEditorTarget
    @State private var name: String
    @State private var color: String?
    @State private var scheduleId: String
    @State private var saveError: String?
    @State private var deleting: TaskCategory?

    init(target: CategoryEditorTarget) {
        self.target = target
        switch target {
        case .new:
            _name = State(initialValue: "")
            _color = State(initialValue: nil)
            _scheduleId = State(initialValue: "")
        case .edit(let category):
            _name = State(initialValue: category.name)
            _color = State(initialValue: category.color)
            _scheduleId = State(initialValue: category.scheduleId)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .disabled(isInbox)
                } footer: {
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if isInbox {
                        Text("Inbox can't be renamed.")
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(CategoryPalette.colors, id: \.hex) { swatch in
                            swatchButton(hex: swatch.hex, name: swatch.name)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Picker("Schedule", selection: $scheduleId) {
                        ForEach(model.schedules) { schedule in
                            Text(schedule.name).tag(schedule.id)
                        }
                    }
                } footer: {
                    Text("The scheduler places this category's tasks only inside these hours. Edit schedules from the Tasks tab.")
                }

                if case .edit(let category) = target, !category.isInbox {
                    Section {
                        Button(role: .destructive) {
                            deleting = category
                        } label: {
                            Label("Delete Category", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .categoryDeleteConfirmation($deleting) {
                dismiss()
            }
            .onAppear {
                if isNew {
                    color = color ?? CategoryPalette.nextColor(after: model.categories)
                    if scheduleId.isEmpty {
                        scheduleId = model.inbox?.scheduleId ?? model.schedules.first?.id ?? ""
                    }
                }
            }
        }
    }

    private var isNew: Bool {
        target == .new
    }

    private var isInbox: Bool {
        if case .edit(let category) = target { return category.isInbox }
        return false
    }

    private func swatchButton(hex: String, name: String) -> some View {
        let selected = color?.uppercased() == hex
        return Button {
            color = hex
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? .accentColor)
                .frame(width: 32, height: 32)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(3)
                .overlay {
                    Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        do {
            switch target {
            case .new:
                try model.createCategory(name: name, color: color, scheduleId: scheduleId.isEmpty ? nil : scheduleId)
            case .edit(let category):
                // The live row, so a reorder or sync since the sheet opened is kept.
                var updated = model.category(id: category.id) ?? category
                updated.name = name
                updated.color = color
                updated.scheduleId = scheduleId
                try model.saveCategory(updated)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
