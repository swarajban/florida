import FloridaKit
import SwiftUI

/// `>New category`: name, color and schedule, created locally on Return.
struct NewCategorySheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var color: String?
    @State private var scheduleId = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New category")
                .font(.headline)
            HStack(spacing: 10) {
                CategoryColorButton(hex: color ?? nextColor) { color = $0 }
                TextField("Name", text: $name)
                    .focused($isNameFocused)
                    .onSubmit(create)
            }
            Picker("Schedule", selection: $scheduleId) {
                ForEach(model.schedules) { schedule in
                    Text(schedule.name).tag(schedule.id)
                }
            }
            HStack {
                Button("Cancel") {
                    model.isNewCategoryOpen = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            scheduleId = model.inboxCategory?.scheduleId ?? model.schedules.first?.id ?? ""
            isNameFocused = true
        }
    }

    /// The color `createCategory` would pick, shown until one is chosen.
    private var nextColor: String {
        let used = Set(model.categories.compactMap(\.color))
        return AppModel.categoryPalette.first { !used.contains($0) } ?? AppModel.categoryPalette[0]
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let created = model.createCategory(
            name: name, color: color ?? nextColor, scheduleId: scheduleId.isEmpty ? nil : scheduleId)
        if created != nil {
            model.isNewCategoryOpen = false
        }
    }
}
