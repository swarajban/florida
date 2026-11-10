import FloridaKit
import SwiftUI

/// A status heading in the Projects sheet: its symbol, name and count, and what the status means
/// for the plan.
struct ProjectSectionHeader: View {
    let section: ProjectSection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: section.status.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(section.status.label)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(section.projects.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(section.status.footnote)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects-section-\(section.status.rawValue)")
    }
}

/// One project in the Projects sheet: its category's color and its name, then the open task
/// count, a Parallel mark and the time held for it each week, with the next step underneath when
/// there is one. The selected row is drawn like the selected task in the task pane.
struct ProjectRowView: View {
    let project: Project
    let category: TaskCategory?
    let openTaskCount: Int
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(category?.tint ?? FloridaStyle.rule)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(project.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    details
                }
                if let nextStep = project.nextStep, !nextStep.isEmpty {
                    Text(ProjectsText.next(nextStep))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? FloridaStyle.ink.opacity(0.08) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(FloridaStyle.ink, lineWidth: isSelected ? 1.5 : 0))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("project-row-\(project.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var details: some View {
        HStack(spacing: 10) {
            if project.parallel {
                Label(ProjectsText.parallel, systemImage: PlanText.parallelSymbol)
                    .labelStyle(.titleAndIcon)
            }
            if let weekly = project.weeklyMinutes, weekly > 0 {
                Text(ProjectsText.weekly(weekly))
            }
            Text(ProjectsText.openTasks(openTaskCount))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}
