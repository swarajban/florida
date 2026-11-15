import FloridaKit
import SwiftUI

struct TaskMetadataEditor: View {
    @Binding var task: TaskItem
    @Binding var tagInput: String
    @State private var tagError: String?
    @FocusState private var focusedInput: String?

    var body: some View {
        Section("Waiting") {
            HStack {
                TextField("Waiting on person or blocker", text: Binding(
                    get: { task.waitingOn ?? "" },
                    set: { task.waitingOn = $0 }))
                    .accessibilityIdentifier("task-waiting-on")
                    .focused($focusedInput, equals: "waiting")
                    .onSubmit { focusedInput = nil }
                    .onChange(of: task.isWaiting) { _, waiting in
                        if waiting { task.pinnedStart = nil } else { task.waitingUntil = nil }
                    }
                if task.isWaiting || task.waitingUntil != nil {
                    Button("Clear", systemImage: "xmark.circle") {
                        task.waitingOn = nil
                        task.waitingUntil = nil
                    }
                    .accessibilityIdentifier("task-waiting-clear")
                }
            }
            if task.isWaiting {
                Toggle("Follow-up", isOn: Binding(
                    get: { task.waitingUntil != nil },
                    set: { task.waitingUntil = $0 ? Date() : nil }))
                    .accessibilityIdentifier("task-follow-up")
                if task.waitingUntil != nil {
                    DatePicker("Follow-up date", selection: Binding(
                        get: { task.waitingUntil ?? Date() },
                        set: { task.waitingUntil = $0 }), displayedComponents: [.date, .hourAndMinute])
                }
                Text("Unpinned while waiting. Without a follow-up, this task stays off the plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section("Tags") {
            if !task.tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(task.tags, id: \.self) { tag in
                            Button {
                                task.tags.removeAll { $0 == tag }
                            } label: {
                                Label("#\(tag)", systemImage: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                    }
                }
            }
            HStack {
                TextField("Add tags (space or comma separated)", text: $tagInput)
                    .accessibilityIdentifier("task-tags-input")
                    .focused($focusedInput, equals: "tags")
                    .onSubmit(addTags)
                Button("Add tags", action: addTags)
                    .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("task-tags-add")
            }
            if let tagError {
                Text(tagError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func addTags() {
        var updated = task
        updated.tags += TaskItem.tagsFromInput(tagInput)
        do {
            try updated.normalizeMetadata()
            task = updated
            tagInput = ""
            tagError = nil
            focusedInput = nil
        } catch {
            tagError = error.localizedDescription
        }
    }
}

struct TaskMetadataCaption: View {
    let task: TaskItem

    var body: some View {
        if task.isWaiting || !task.tags.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if task.isWaiting {
                    HStack(spacing: 4) {
                        Text("Waiting: \(task.waitingOn ?? "")")
                        if let date = task.waitingUntil {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .lineLimit(1)
                }
                if !task.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(task.tags.prefix(3)), id: \.self) { tag in
                            Text("#\(tag)")
                                .padding(.horizontal, 5)
                                .background(.quaternary, in: Capsule())
                        }
                        if task.tags.count > 3 { Text("+\(task.tags.count - 3)") }
                    }
                    .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
