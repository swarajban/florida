import FloridaKit
import SwiftUI

struct InboxDueDateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem
    @State private var date = Date()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(task.title).font(.headline)
                    DatePicker("Due", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .accessibilityIdentifier("inbox-due-date-picker")
                    if let error {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Set due date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("inbox-due-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set date") {
                        do {
                            try model.setInboxDueDate(task, to: date)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("inbox-due-save")
                }
            }
            .onAppear {
                let due = TaskDay.defaultDue(now: Date(), calendar: model.calendar)
                date = task.startAt.map { TaskDay.due(due, notBefore: $0, calendar: model.calendar) } ?? due
            }
        }
        .environment(\.calendar, model.calendar)
        .environment(\.timeZone, model.calendar.timeZone)
    }
}
