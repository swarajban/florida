import FloridaKit
import SwiftUI

/// A faint "42 min free" (or "1h 30m free") between two timeline items. Tapping it lists the open tasks that fit
/// (up to three, most urgent first); tapping one pins it at the start of the gap.
struct FreeGapRow: View {
    @Environment(AppModel.self) private var model
    let gap: FreeGap
    @State private var showingTasks = false

    var body: some View {
        Button {
            showingTasks = true
        } label: {
            HStack(spacing: 8) {
                Color.clear
                    .frame(width: TimeColumn.width)
                Image(systemName: "sparkle")
                    .font(.caption2)
                Text("\(Formatting.freeTime(minutes: gap.minutes)) free")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .accessibilityLabel("\(Formatting.spokenDuration(minutes: gap.minutes)) free from \(Formatting.time(gap.start))")
        .accessibilityHint("Shows tasks that fit")
        .popover(isPresented: $showingTasks) {
            fittingTasks
                .presentationCompactAdaptation(.popover)
        }
    }

    private var fittingTasks: some View {
        let tasks = model.tasksFitting(minutes: gap.minutes, at: gap.start)
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(Formatting.freeTime(minutes: gap.minutes)) free at \(Formatting.time(gap.start))")
                .font(.headline)
            if tasks.isEmpty {
                Text("No open task fits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(tasks) { task in
                Button {
                    showingTasks = false
                    model.pin(task, at: gap.start)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.category(model.category(id: task.categoryId)))
                            .frame(width: 8, height: 8)
                        Text(task.title)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Formatting.duration(minutes: task.remainingMinutes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "pin")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pin \(task.title) at \(Formatting.time(gap.start))")
            }
        }
        .padding()
        .frame(minWidth: 280, alignment: .leading)
    }
}
