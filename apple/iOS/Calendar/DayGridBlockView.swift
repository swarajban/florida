import FloridaKit
import SwiftUI

/// One block on the grid: an event in its calendar color with the account rim, a task block in
/// its category color (dashed until pinned), a ghost, a suggestion for an optional routine
/// block (dotted, barely filled, with a moon), or a plan block: a commitment (the gym) in ink or
/// project time in its project's category color, hatched with a thin solid outline and its
/// `PlanText` symbol, so held time reads apart from meetings and tasks. Sized and placed by the
/// parent; shows the time range when tall enough. `isLifted` draws the copy that follows the
/// finger (opaque; the parent adds its shadow and scale, so idle blocks carry neither).
struct DayGridBlockView: View {
    let block: DayGridLayout.Block
    /// The block's own time, or the slot it is being dragged over.
    let timeText: String
    let showsTime: Bool
    let isPast: Bool
    var isLifted = false
    /// Plan blocks: wide enough for the symbol before the title. One that shares its time in a
    /// three-day grid is not, and keeps its few points for the title.
    var showsSymbol = true
    /// Project time: tall enough for the time range under "Project time".
    var showsThirdLine = false

    /// What UI tests find a plan block by: "grid-plan-" and the block's id, such as
    /// "grid-plan-commitment:gym@<start>". Events and task blocks carry no identifier.
    static func planIdentifier(_ plan: PlanBlock) -> String {
        "grid-plan-\(plan.id)"
    }

    private var alpha: Double {
        block.isDone ? 0.5 : (isPast || block.isSuggestion ? 0.6 : 1)
    }

    var body: some View {
        if let plan = block.planBlock {
            content.accessibilityIdentifier(Self.planIdentifier(plan))
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        let textColor = FloridaStyle.ink.opacity(alpha)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 2) {
                if block.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .padding(.top, 2)
                } else if showsSymbol, let planSymbol {
                    Image(systemName: planSymbol)
                        .font(.system(size: 10))
                        .padding(.top, 2)
                }
                Text(block.title)
                    .font(.caption.weight(.medium))
                    .strikethrough(block.isDone)
                    .lineLimit(showsTime ? 2 : 1)
                Spacer(minLength: 0)
                if block.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .padding(.top, 2)
                } else if block.isSuggestion {
                    Image(systemName: "moon.stars")
                        .font(.system(size: 9))
                        .padding(.top, 2)
                }
            }
            if showsTime, let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.85)
            }
            if showsTime, subtitle == nil || showsThirdLine {
                Text(timeText)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, block.rim == nil ? 5 : 7)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // In front of the fill, behind the text; clipped to the block's shape below.
            if block.isPlan {
                PlanHatch().stroke(block.tint.opacity(0.18 * alpha), lineWidth: 1)
            }
        }
        .background(block.tint.opacity(fillOpacity), in: shape)
        .background {
            // Behind the tint (each `background` goes further back): the lifted copy is opaque
            // over the blocks it passes.
            if isLifted {
                shape.fill(FloridaStyle.paper)
            }
        }
        .overlay {
            shape.strokeBorder(
                block.tint.opacity(strokeOpacity),
                style: StrokeStyle(lineWidth: 1, dash: block.isSuggestion ? [1, 3] : (dashed ? [3, 2] : [])))
        }
        .overlay(alignment: .leading) {
            if let rim = block.rim {
                RoundedRectangle(cornerRadius: 1)
                    .fill(rim.opacity(alpha))
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
        .clipShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(timeText)
        // A plan block does nothing on a tap yet (`DayGridView.onSelectPlanBlock`), so it is not
        // announced as a button.
        .accessibilityAddTraits(block.isPlan ? [] : .isButton)
    }

    /// Plan blocks: the commitment's or the project's symbol.
    private var planSymbol: String? {
        guard let plan = block.planBlock else { return nil }
        return plan.isCommitment ? PlanText.commitmentSymbol : PlanText.projectSymbol
    }

    /// "Project time" under the title of time held for a project; nil for every other block.
    private var subtitle: String? {
        guard let plan = block.planBlock, !plan.isCommitment else { return nil }
        return PlanText.projectTime
    }

    private var fillOpacity: Double {
        if block.isSuggestion { return 0.03 }
        if block.isPlan { return 0.05 * alpha }
        return (block.isEvent ? 0.12 : 0.08) * alpha + (isLifted ? 0.1 : 0)
    }

    private var strokeOpacity: Double {
        if block.isPlan { return 0.4 * alpha }
        return (block.isEvent ? 0.5 : 0.6) * alpha
    }

    /// Task blocks the scheduler may still move are dashed; pinned ones, events and plan blocks
    /// are solid.
    private var dashed: Bool {
        !block.isEvent && !block.isPinned && !block.isPlan
    }

    private var accessibilityLabel: String {
        var parts = [block.isSuggestion ? "Suggestion: \(block.title)" : block.title]
        if let subtitle { parts.append(subtitle) }
        if block.isPinned { parts.append("pinned") }
        if block.isDone { parts.append("done") }
        return parts.joined(separator: ", ")
    }
}

/// Diagonal lines across a plan block: time that is held, not a meeting and not a task.
private struct PlanHatch: Shape {
    func path(in rect: CGRect) -> Path {
        let spacing: CGFloat = 6
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
