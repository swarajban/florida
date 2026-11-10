import FloridaKit
import SwiftUI

/// Under a day's timeline: what the scheduler would do in one optional routine block ("Evening,
/// if you're up for it · 2h 30m"). Nothing here is on the plan; "Do tonight" pins the task at the
/// suggested start, which moves it onto the plan and out of this section at once.
struct OptionalPicksSection: View {
    @Environment(AppModel.self) private var model
    let group: OptionalPicks
    let now: Date
    let onEdit: (TaskItem) -> Void

    var body: some View {
        Section {
            ForEach(group.picks) { pick in
                OptionalPickRow(
                    pick: pick, category: model.category(id: pick.task.categoryId),
                    takeTitle: RoutineText.takeTitle(pick.placement, now: now, calendar: model.calendar),
                    onEdit: { onEdit(pick.task) }, onTake: { model.take(pick) })
                    .listRowBackground(FloridaStyle.paper)
            }
            // The last row, not the section's footer: a plain list draws a footer as a bar in the
            // system background with body-size text, a white slab on the paper.
            Text("Suggestions only: none of this is on the plan.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
                .listRowBackground(FloridaStyle.paper)
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "moon.stars")
                    .accessibilityHidden(true)
                Text("\(RoutineText.picksTitle(group)) · \(Formatting.duration(minutes: group.totalMinutes))")
            }
            .font(.subheadline.weight(.semibold))
            .textCase(nil)
            .accessibilityLabel(
                "\(RoutineText.picksTitle(group)), \(Formatting.spokenDuration(minutes: group.totalMinutes))")
        }
    }
}

/// One suggestion: its time, the task (tap to edit) and the button that takes it. The row and
/// the button are separate borderless buttons, as in `TaskListRow`, so a tap on one never fires
/// the other.
struct OptionalPickRow: View {
    let pick: OptionalPicks.Pick
    let category: TaskCategory?
    let takeTitle: String
    let onEdit: () -> Void
    let onTake: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onEdit) {
                HStack(alignment: .top, spacing: 12) {
                    TimeColumn(start: pick.placement.startAt, end: pick.placement.endAt)
                    // Dotted where a planned block's bar is solid: a suggestion, not a commitment.
                    Line()
                        .stroke(Color.category(category), style: StrokeStyle(lineWidth: 3, dash: [3, 3]))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pick.task.title)
                            .font(.body)
                            .multilineTextAlignment(.leading)
                        Text("\(category?.name ?? "No category") · \(Formatting.duration(minutes: pick.minutes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .accessibilityHint("Edits the task")
            Button(takeTitle, action: onTake)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Pins the task at \(Formatting.time(pick.placement.startAt))")
        }
        .padding(.vertical, 8)
    }

    /// A vertical line down the middle of its frame.
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }
}
