import FloridaKit
import SwiftUI

/// A commitment the scheduler placed (the gym) or time it holds for a project, in the day
/// timeline. Laid out like a task block, but with an outlined bar where a task's is dashed and a
/// meeting is a filled card, and the plan's symbol where a task has its circle: scheduled time
/// that is neither a task nor a meeting. Project time says so under the title.
struct PlanBlockRow: View {
    /// Where the title starts: the time column, the bar, and the spacing on both sides of it.
    static let titleInset: CGFloat = TimeColumn.width + 12 + HeldTimeBar.width + 12

    let block: PlanBlock
    /// The category of the project the time is held for, for its color; nil for a commitment.
    let category: TaskCategory?
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimeColumn(start: block.startAt, end: block.endAt)
            HeldTimeBar(color: category.map { Color.category($0) } ?? .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: block.isCommitment ? PlanText.commitmentSymbol : PlanText.projectSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(block.title)
                        .font(.body)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .opacity(AgendaItem.plan(block).isOver(at: now) ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agenda-plan-\(block.id)")
    }

    /// "Project time · 1h" for project time; a commitment's name says what it is, so only "1h 15m".
    private var subtitle: String {
        let duration = Formatting.duration(minutes: block.minutes)
        return block.isCommitment ? duration : "\(PlanText.projectTime) · \(duration)"
    }
}

/// The bar of a plan block: an outline in the color a task's bar would be filled with.
private struct HeldTimeBar: View {
    static let width: CGFloat = 5

    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: Self.width / 2)
            .strokeBorder(color, lineWidth: 1.5)
            .frame(width: Self.width)
            .accessibilityHidden(true)
    }
}

/// "Alongside Infosec audit and Florida" under a task block or project time that shares its time
/// with work in other lanes. A line of its own under the block's row, not part of it: the row
/// keeps the accessibility text it had, and the caption can be found by its identifier
/// ("agenda-alongside-" and the `Placement.id` or `PlanBlock.id`).
struct AlongsideCaption: View {
    /// The `Placement.id` or `PlanBlock.id` of the block above.
    let id: String
    /// Titles of the work in the other lanes, from `ParallelWork.companionTitles`.
    let titles: [String]
    /// Where the title of the row above starts, so the caption lines up under it.
    let inset: CGFloat
    /// The block above is over and drawn dimmed.
    var isOver = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: PlanText.parallelSymbol)
                .font(.caption2)
                .accessibilityHidden(true)
            Text(PlanText.alongside(titles))
                .font(.caption)
                .multilineTextAlignment(.leading)
                .accessibilityIdentifier("agenda-alongside-\(id)")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, inset)
        .padding(.bottom, 8)
        .opacity(isOver ? 0.55 : 1)
    }
}

/// What the plan as a whole says about the day, as one quiet row above the timeline: the day's
/// open time and, on today, the commitments that found no slot this week.
struct DayPlanNotes: View {
    /// SF Symbol for the day's open time. `PlanText` has none; the free-gap rows' "sparkle" would
    /// read as one more AI mark next to the brief.
    static let freeSymbol = "clock"

    /// "1h 30m free", from `PlanText.free`.
    let free: String?
    /// "Gym: no free slot for the extra session this week", from `PlanText.missed`.
    let missed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let free {
                line(free, symbol: Self.freeSymbol)
                    .accessibilityIdentifier("agenda-free-time")
            }
            if let missed {
                line(missed, symbol: PlanText.commitmentSymbol)
                    .accessibilityIdentifier("agenda-missed-commitments")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// The symbols differ in width, so each sits in a fixed column and the two lines' text aligns.
    private func line(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }
}
