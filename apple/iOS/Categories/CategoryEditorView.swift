import FloridaKit
import SwiftUI

/// Sheet to add or edit a category: name, color, and whether it is work or personal.
/// Inbox keeps its name and cannot be deleted. Errors show in place; nothing waits on the server.
struct CategoryEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: CategoryEditorTarget
    @State private var name: String
    @State private var color: String?
    @State private var area: CategoryArea?
    @State private var saveError: String?
    @State private var deleting: TaskCategory?

    init(target: CategoryEditorTarget) {
        self.target = target
        switch target {
        case .new:
            _name = State(initialValue: "")
            _color = State(initialValue: nil)
            _area = State(initialValue: nil)
        case .edit(let category):
            _name = State(initialValue: category.name)
            _color = State(initialValue: category.color)
            _area = State(initialValue: category.area)
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

                if !isInbox {
                    Section {
                        Picker("Area", selection: $area) {
                            // Offered only until an area is saved: a write without an area leaves
                            // the server's as it is, so the choice could not be taken back.
                            if storedArea == nil {
                                Text("Not set").tag(CategoryArea?.none)
                            }
                            ForEach(CategoryArea.allCases, id: \.self) { area in
                                Text(area.displayName).tag(CategoryArea?.some(area))
                            }
                        }
                    } footer: {
                        Text(CategoryArea.footnote)
                    }
                }

                if case .edit(let category) = target, !category.isInbox {
                    Section {
                        Button(role: .destructive) {
                            deleting = category
                        } label: {
                            Label("Delete Category", systemImage: "trash")
                        }
                        .categoryDeleteConfirmation($deleting) {
                            dismiss()
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
            .onAppear {
                if isNew {
                    color = color ?? CategoryPalette.nextColor(after: model.categories)
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

    /// The area the category had when the sheet opened; nil for a new one.
    private var storedArea: CategoryArea? {
        if case .edit(let category) = target { return category.area }
        return nil
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
                try model.createCategory(name: name, color: color, area: area)
            case .edit(let category):
                // The live row, so a reorder or sync since the sheet opened is kept.
                var updated = model.category(id: category.id) ?? category
                updated.name = name
                updated.color = color
                updated.area = area
                try model.saveCategory(updated)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
