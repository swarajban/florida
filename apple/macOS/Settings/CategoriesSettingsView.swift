import FloridaKit
import SwiftUI

/// Categories: Inbox (fixed), then work, then personal, by name within each, as in every list and
/// picker. Each row has its color, name, task count and whether it is work or personal; a row
/// moves to its place when its name or area changes. Every change saves locally at once and
/// syncs in the background.
struct CategoriesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            List {
                if let inbox = model.categories.first(where: \.isInbox) {
                    Section {
                        CategorySettingsRow(category: inbox)
                    } footer: {
                        Text("New tasks land in Inbox until you triage them. It can't be renamed or deleted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Categories") {
                    ForEach(model.orderedCategories.filter { !$0.isInbox }) { category in
                        CategorySettingsRow(category: category)
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    model.createCategory(name: "New category")
                } label: {
                    Label("Add Category", systemImage: "plus")
                }
                Spacer()
                Text("Work first, then personal, by name · deleting moves its tasks to Inbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }
}

/// One category: color, name (fixed for Inbox), open task count, work or personal, delete.
struct CategorySettingsRow: View {
    @Environment(AppModel.self) private var model
    let category: TaskCategory
    @State private var name = ""
    @State private var isConfirmingDelete = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        let count = model.taskCount(inCategory: category.id)
        HStack(spacing: 10) {
            CategoryColorButton(hex: category.color) { hex in
                var updated = category
                updated.color = hex
                model.save(updated)
            }
            if category.isInbox {
                Text(category.name)
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($isNameFocused)
                    .onSubmit(commitName)
                    .onChange(of: isNameFocused) { _, focused in
                        if !focused { commitName() }
                    }
            }
            Spacer()
            Text("\(count) open")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !category.isInbox {
                MacChoiceField(
                    "Area", selection: areaBinding,
                    options: (category.area == nil ? [MacChoice(CategoryArea?.none, "Not set")] : [])
                        + CategoryArea.allCases.map { MacChoice(CategoryArea?.some($0), $0.displayName) },
                    identifier: "category-area-\(category.id)", showsLabel: false)
                .frame(width: 110)
                .help(CategoryArea.footnote)
            }
            Button {
                isConfirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(category.isInbox)
            .help(category.isInbox ? "Inbox can't be deleted" : "Delete")
        }
        .onAppear { name = category.name }
        .onChange(of: category.name) { _, newName in
            if !isNameFocused { name = newName }
        }
        .confirmationDialog("Delete “\(category.name)”?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                model.deleteCategory(category)
            }
        } message: {
            Text(count == 0 ? "It has no open tasks." : "Its \(count) open task\(count == 1 ? "" : "s") will move to Inbox.")
        }
    }

    private var areaBinding: Binding<CategoryArea?> {
        Binding(
            get: { category.area },
            set: { area in
                var updated = category
                updated.area = area
                model.save(updated)
            })
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            name = category.name
            return
        }
        guard trimmed != category.name else { return }
        var updated = category
        updated.name = trimmed
        model.save(updated)
    }
}
