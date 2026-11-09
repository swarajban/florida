import FloridaKit
import SwiftUI

/// "Done for now": how many minutes of the task got done. Defaults to the time since its block
/// started when one is in progress; the rest stays open and is scheduled again.
struct DoneForNowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem
    @State private var minutes: Int?

    var body: some View {
        let remaining = max(1, task.remainingMinutes)
        let value = minutes ?? model.suggestedDoneMinutes(for: task)
        NavigationStack {
            Form {
                Section {
                    Stepper(value: Binding(get: { value }, set: { minutes = $0 }), in: 1...remaining, step: 5) {
                        LabeledContent("Done", value: Formatting.duration(minutes: value))
                            .monospacedDigit()
                    }
                } header: {
                    Text(task.title)
                        .textCase(nil)
                } footer: {
                    if value >= remaining {
                        Text("That is all of it; the task will be completed.")
                    } else {
                        Text("\(Formatting.duration(minutes: remaining - value)) stays on the task and gets rescheduled.")
                    }
                }
            }
            .navigationTitle("Done for Now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.doneForNow(task, minutes: value)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(260), .medium])
    }
}
