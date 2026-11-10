import FloridaKit
import SwiftUI

/// Heading over today's suggestions for one optional routine block, on top of the task pane:
/// "Evening, if you're up for it" and how much time the suggestions add up to.
struct OptionalPicksHeader: View {
    let group: OptionalPicks

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.stars")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(RoutineText.picksTitle(group))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(DateText.duration(minutes: group.totalMinutes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(FloridaStyle.panel)
    }
}

/// One suggestion: the task, when it would go, and the button that takes it (`p` on the selected
/// row does the same). Taking pins the task at the suggested start, which moves it onto the plan
/// and out of the suggestions at once. Its edge is dotted where a planned task's is solid.
struct OptionalPickRowView: View {
    let pick: OptionalPicks.Pick
    let category: TaskCategory?
    let takeTitle: String
    let isSelected: Bool
    let isFocused: Bool
    /// Jump mode's label for this suggestion, shown before its title.
    let jumpLabel: String?
    let onTake: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let jumpLabel {
                JumpBadge(label: jumpLabel)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(pick.task.title)
                    .lineLimit(2)
                Text("\(DateText.timeRange(pick.placement.startAt, pick.placement.endAt)) · \(category?.name ?? "No category")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(takeTitle, action: onTake)
                .controlSize(.small)
                .help("Pins the task at \(DateText.time(pick.placement.startAt)) (P)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? FloridaStyle.ink.opacity(isFocused ? 0.08 : 0.04) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(FloridaStyle.ink, lineWidth: isSelected && isFocused ? 1.5 : 0))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .stroke(category?.tint ?? .defaultCategory, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}
