import FloridaKit
import SwiftUI

/// ⇧Space: how many minutes were just worked on a task. Logging adds them to the task's
/// completed minutes (finishing it if nothing is left); the scheduler places the rest.
struct DoneForNowSheet: View {
    @Environment(AppModel.self) private var model
    let request: DoneForNowRequest
    @State private var minutes: Int
    @FocusState private var isFieldFocused: Bool

    init(request: DoneForNowRequest) {
        self.request = request
        _minutes = State(initialValue: request.defaultMinutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Done for now")
                .font(.headline)
            Text(request.title)
                .lineLimit(2)
            HStack {
                TextField("Minutes", value: $minutes, format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .focused($isFieldFocused)
                    .onSubmit(log)
                Stepper("Minutes", value: $minutes, in: 1...max(1, request.remainingMinutes), step: 5)
                    .labelsHidden()
                Text("minutes worked")
                    .foregroundStyle(.secondary)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") {
                    model.doneForNow = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Log") {
                    log()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(minutes < 1)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            isFieldFocused = true
        }
    }

    private var summary: String {
        let left = max(0, request.remainingMinutes - minutes)
        return left == 0 ? "That finishes it." : "\(DateText.duration(minutes: left)) left to schedule."
    }

    private func log() {
        guard minutes >= 1 else { return }
        model.doneForNow = nil
        model.logProgress(taskId: request.taskId, minutes: min(minutes, request.remainingMinutes))
    }
}
