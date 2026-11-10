import FloridaKit
import SwiftUI

/// One project in the Projects list: its category's color, its name, the next step when there is
/// one, then the open task count, a Parallel mark, and the time held for it each week.
struct ProjectRow: View {
    let project: Project
    let category: TaskCategory?
    let openTaskCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Filled with the category's color; an outline when the project has no category.
            Group {
                if let category {
                    Circle()
                        .fill(Color.category(category))
                } else {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1.5)
                }
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: project.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let nextStep = project.nextStep, !nextStep.isEmpty {
                    Text(verbatim: "Next: \(nextStep)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // One line when it fits; stacked at the largest text sizes rather than truncated.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        details(separated: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        details(separated: false)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func details(separated: Bool) -> some View {
        Text(openTasks)
        if project.parallel {
            if separated { separator }
            // Inline, not a Label: a List gives a Label's icon its own column and starts the
            // row separator at the Label's title.
            Text("\(Image(systemName: PlanText.parallelSymbol)) Parallel")
                .accessibilityLabel("Parallel")
        }
        if let weekly = project.weeklyMinutes, weekly > 0 {
            if separated { separator }
            Text("\(Formatting.duration(minutes: weekly)) a week")
                .accessibilityLabel("\(Formatting.spokenDuration(minutes: weekly)) a week")
        }
    }

    private var separator: some View {
        Text("·")
            .accessibilityHidden(true)
    }

    /// "3 open tasks", "1 open task", "No open tasks".
    private var openTasks: String {
        switch openTaskCount {
        case 0: "No open tasks"
        case 1: "1 open task"
        default: "\(openTaskCount) open tasks"
        }
    }
}
